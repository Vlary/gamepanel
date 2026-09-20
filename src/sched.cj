package gamepanel

/*
 * 计划任务调度器：五段 cron 表达式 + 到点触发。
 * 实现原则——简单可推理：
 *   1. 解析时把每个字段展开成"允许值集合"
 *   2. nextRun 用逐分钟试探法计算（后台线程，最多 53 万次迭代，毫秒级完成）
 *   3. 调度线程每 20 秒醒来一次，把到点的任务派发给子线程执行
 * 注意：日(day) 与 周(week) 同时受限时按"同时满足"处理（简化语义，面板内注明）。
 */

import stdx.net.http.*
import stdx.encoding.json.*
import std.sync.*
import std.time.*
import std.collection.*
import std.convert.*

/* cron 单字段解析结果：允许值集合；any=true 表示 * */
public class CronField {
    public let values = HashSet<Int64>()
    public var any = false

    public init() {}

    public func allows(v: Int64): Bool {
        if (any) {
            return true
        }
        return values.contains(v)
    }
}

public class Cron {
    public let minute = CronField()
    public let hour = CronField()
    public let dom = CronField()    // day of month 1-31
    public let month = CronField()  // 1-12
    public let dow = CronField()    // 0-6，0=周日

    /* 解析 "分 时 日 月 周"，非法返回错误说明 */
    public static func parse(expr: String): ?Cron {
        let parts = expr.trimAscii().split(" ")
        if (parts.size != 5) {
            return None
        }
        let fields = [parts[0], parts[1], parts[2], parts[3], parts[4]]
        let ranges = [(0, 59), (0, 23), (1, 31), (1, 12), (0, 6)]
        let c = Cron()
        let targets = [c.minute, c.hour, c.dom, c.month, c.dow]
        for (i in 0..5) {
            match (parseField(fields[i], ranges[i][0], ranges[i][1])) {
                case Some(f) => copyInto(targets[i], f)
                case None => return None
            }
        }
        return Some(c)
    }

    private static func copyInto(dst: CronField, src: CronField) {
        dst.any = src.any
        for (v in src.values) {
            dst.values.add(v)
        }
    }

    /* 解析单字段: 任意段支持 * / 步长 / 范围 / 逗号列表 */
    public static func parseField(text: String, min: Int64, max: Int64): ?CronField {
        let f = CronField()
        for (piece in text.split(",")) {
            var body = piece
            var step: Int64 = 1
            // 处理 */n 与 a-b/n
            let slashIdx = idxOf(piece, "/")
            if (slashIdx >= 0) {
                body = piece[..slashIdx]
                let stepText = piece[slashIdx + 1..]
                try {
                    step = Int64.parse(stepText)
                } catch (_: Exception) {
                    return None
                }
                if (step <= 0) {
                    return None
                }
            }
            var lo: Int64 = min
            var hi: Int64 = max
            if (body == "*") {
                // 保持全范围
            } else {
                let dashIdx = idxOf(body, "-")
                try {
                    if (dashIdx >= 0) {
                        lo = Int64.parse(body[..dashIdx])
                        hi = Int64.parse(body[dashIdx + 1..])
                    } else {
                        lo = Int64.parse(body)
                        hi = lo
                    }
                } catch (_: Exception) {
                    return None
                }
            }
            if (lo < min || hi > max || lo > hi) {
                return None
            }
            if (body == "*" && slashIdx < 0) {
                f.any = true
                continue
            }
            var v = lo
            while (v <= hi) {
                f.values.add(v)
                v += step
            }
        }
        // 任意段全集合等价于 *
        if (f.values.size == max - min + 1) {
            f.any = true
        }
        return Some(f)
    }

    /* 该时刻是否命中 */
    public func matches(dt: DateTime): Bool {
        return minute.allows(Int64(dt.minute)) &&
            hour.allows(Int64(dt.hour)) &&
            dom.allows(Int64(dt.dayOfMonth)) &&
            month.allows(monthNum(dt.month)) &&
            dow.allows(dowNum(dt.dayOfWeek))
    }

    /* 从 from 之后第一个命中时刻；找不到（配置错误如 2 月 31 日）返回 None */
    public func nextAfter(from: DateTime): ?DateTime {
        var dt = from + Duration.minute
        // 对齐到分钟起点，避免秒数导致的抖动
        dt = DateTime.parse(dt.format("yyyy-MM-dd HH:mm:00"), "yyyy-MM-dd HH:mm:ss")
        let limitMinutes: Int64 = 366 * 24 * 60 * 2
        var i: Int64 = 0
        while (i < limitMinutes) {
            if (matches(dt)) {
                return Some(dt)
            }
            dt += Duration.minute
            i += 1
        }
        return None
    }

    /* 月份/星期枚举转数字 */
    private static func monthNum(m: Month): Int64 {
        let names = ["January", "February", "March", "April", "May", "June",
            "July", "August", "September", "October", "November", "December"]
        let s = m.toString()
        for (i in 0..names.size) {
            if (names[i] == s) {
                return i + 1
            }
        }
        return 1
    }

    private static func dowNum(d: DayOfWeek): Int64 {
        let names = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]
        let s = d.toString()
        for (i in 0..names.size) {
            if (names[i] == s) {
                return i
            }
        }
        return 0
    }
}

/* ---------------- 调度线程 ---------------- */

public class Scheduler {
    public static func start() {
        spawn {
            loop()
        }
    }

    static private func loop(): Unit {
        // 启动时为所有任务预算 nextRun
        refreshAllNextRuns()
        while (true) {
            sleep(20 * Duration.second)
            let now = DateTime.now()
            for (t in Store.data().tasks) {
                if (!t.enabled || t.nextRun == "") {
                    continue
                }
                try {
                    let due = DateTime.parse(t.nextRun, "yyyy-MM-dd HH:mm")
                    if (now >= due) {
                        dispatch(t)
                    }
                } catch (_: Exception) {
                    ()
                }
            }
        }
    }

    /* 逐条预算下一次运行时间（启动/修改时调用） */
    public static func refreshAllNextRuns() {
        Store.update({ d =>
            for (t in d.tasks) {
                refreshNextRun(t)
            }
        })
    }

    public static func refreshNextRun(t: TaskItem) {
        match (Cron.parse(t.cron)) {
            case Some(c) =>
                match (c.nextAfter(DateTime.now())) {
                    case Some(dt) => t.nextRun = dt.format("yyyy-MM-dd HH:mm")
                    case None => t.nextRun = ""
                }
            case None => t.nextRun = ""
        }
    }

    /* 到点执行：派发子线程，避免长任务（tar 备份）阻塞调度 */
    static private func dispatch(t: TaskItem) {
        Store.update({ d =>
            match (d.findTask(t.id)) {
                case Some(cur) =>
                    cur.lastRun = Instances.nowStr()
                    refreshNextRun(cur)
                case None => ()
            }
        })
        spawn {
            execAction(t)
        }
    }

    /* 立即执行一次（"执行"按钮 / 到点触发共用） */
    static public func runOnce(t: TaskItem): Unit {
        spawn {
            execAction(t)
        }
    }

    /* 动作执行：动作失败只写日志，不打断调度 */
    static public func execAction(t: TaskItem) {
        let ins = match (Store.data().findInstance(t.instanceId)) {
            case Some(i) => i
            case None => println("[sched] 任务 ${t.name}：实例不存在"); return
        }
        var err: ?String = None
        match (t.action) {
            case "backup" => err = Backups.createBackup(ins, t.name, true)
            case "snapshot" => err = Backups.createSnapshot(ins, t.name, true)
            case "start" =>
                let r = Docker.start(ins.containerName(), node: ins.node)
                if (r.ok()) {
                    ConsolePipe.attach(ins)
                } else {
                    err = Some(r.stderr.trimAscii())
                }
            case "stop" =>
                ConsolePipe.detach(ins.id)
                let r = Docker.stop(ins.containerName(), node: ins.node)
                if (!r.ok()) {
                    err = Some(r.stderr.trimAscii())
                }
            case "restart" =>
                ConsolePipe.detach(ins.id)
                let r = Docker.restart(ins.containerName(), node: ins.node)
                if (r.ok()) {
                    ConsolePipe.attach(ins)
                } else {
                    err = Some(r.stderr.trimAscii())
                }
            case "command" =>
                if (!ConsolePipe.send(ins, t.command)) {
                    err = Some("命令发送失败")
                }
            case _ => err = Some("未知动作: ${t.action}")
        }
        match (err) {
            case Some(e) => println("[sched] 任务 ${t.name} 执行失败: ${e}")
            case None => ()
        }
        // 备份/快照类动作执行保留策略
        if (t.action == "backup" || t.action == "snapshot") {
            Backups.prune(t.instanceId, t.action, t.keepCount)
        }
    }
}

/* ---------------- REST 路由 ---------------- */

public func registerTaskRoutes(): Unit {
    router.get("/api/v1/tasks", { ctx, _ =>
        if (!Auth.guard(ctx)) {
            return
        }
        let arr = JsonArray()
        for (t in Store.data().tasks) {
            arr.add(t.toJson())
        }
        HttpUtil.ok(ctx, arr)
    })

    router.post("/api/v1/tasks", { ctx, _ =>
        if (!Auth.guard(ctx)) {
            return
        }
        let body = HttpUtil.bodyJson(ctx)
        let instanceId = HttpUtil.str(body, "instanceId", "")
        var instanceFound = false
        match (Store.data().findInstance(instanceId)) {
            case Some(_) => instanceFound = true
            case None => ()
        }
        if (!instanceFound) {
            HttpUtil.fail(ctx, 404, "实例不存在")
            return
        }
        let cron = HttpUtil.str(body, "cron", "").trimAscii()
        match (Cron.parse(cron)) {
            case None => HttpUtil.fail(ctx, 5001, "cron 表达式非法（五段：分 时 日 月 周，如 0 4 * * *）")
            case Some(_) =>
                let action = HttpUtil.str(body, "action", "")
                let legal = ["backup", "snapshot", "start", "stop", "restart", "command"]
                if (!legal.contains(action)) {
                    HttpUtil.fail(ctx, 5002, "action 必须是 ${legal.toString()} 之一")
                    return
                }
                let t = TaskItem()
                t.id = Backups.genRecId()
                t.instanceId = instanceId
                t.name = HttpUtil.str(body, "name", "计划任务")
                t.cron = cron
                t.action = action
                t.command = HttpUtil.str(body, "command", "")
                t.enabled = HttpUtil.boolean(body, "enabled", true)
                t.keepCount = HttpUtil.int(body, "keepCount", 7)
                t.createdAt = Instances.nowStr()
                Store.update({ d =>
                    Scheduler.refreshNextRun(t)
                    d.tasks.add(t)
                })
                HttpUtil.okMsg(ctx, "任务已创建，下次运行: ${t.nextRun}")
        }
    })

    router.put("/api/v1/tasks/{id}", { ctx, md =>
        if (!Auth.guard(ctx)) {
            return
        }
        match (Store.data().findTask(md.matchString("id"))) {
            case Some(old) =>
                let body = HttpUtil.bodyJson(ctx)
                match (Store.data().findTask(old.id)) {
                    case Some(cur) =>
                        Store.update({ d =>
                            match (d.findTask(old.id)) {
                                case Some(t) =>
                                    t.name = HttpUtil.str(body, "name", t.name)
                                    t.enabled = HttpUtil.boolean(body, "enabled", t.enabled)
                                    t.keepCount = HttpUtil.int(body, "keepCount", t.keepCount)
                                    t.command = HttpUtil.str(body, "command", t.command)
                                    let newCron = HttpUtil.str(body, "cron", t.cron).trimAscii()
                                    if (newCron != t.cron) {
                                        match (Cron.parse(newCron)) {
                                            case Some(_) => t.cron = newCron
                                            case None => ()
                                        }
                                    }
                                    Scheduler.refreshNextRun(t)
                                case None => ()
                            }
                        })
                        HttpUtil.okMsg(ctx, "已更新")
                    case None => HttpUtil.fail(ctx, 404, "任务不存在")
                }
            case None => HttpUtil.fail(ctx, 404, "任务不存在")
        }
    })

    router.post("/api/v1/tasks/{id}/run", { ctx, md =>
        if (!Auth.guard(ctx)) {
            return
        }
        match (Store.data().findTask(md.matchString("id"))) {
            case Some(t) =>
                Scheduler.runOnce(t)
                HttpUtil.okMsg(ctx, "已开始执行：${t.name}")
            case None => HttpUtil.fail(ctx, 404, "任务不存在")
        }
    })

    router.delete("/api/v1/tasks/{id}", { ctx, md =>
        if (!Auth.guard(ctx)) {
            return
        }
        Store.update({ d => d.tasks.removeIf({ t => t.id == md.matchString("id") }) })
        HttpUtil.okMsg(ctx, "已删除")
    })
}
