package gamepanel

/*
 * 实例管理：创建向导、生命周期（启动/停止/重启/删除）、状态聚合、设置变更。
 * 容器与数据目录的生命周期约定：
 *   - 删除实例 = 删容器 + 删数据目录 + 删备份快照（前端二次确认）
 *   - 换版本/改设置 = 重建容器，数据目录永远保留
 */

import stdx.net.http.*
import stdx.encoding.json.*
import std.fs.*
import std.random.*
import std.time.*
import std.sync.*
import std.convert.*
import std.collection.*

/* indexOf 返回 Option，这里统一转 -1 便于切片 */
func idxOf(s: String, sub: String): Int64 {
    match (s.indexOf(sub)) {
        case Some(i) => i
        case None => -1
    }
}

public class Instances {
    private static let mutex = Mutex()
    private static var idSeq: Int64 = 0
    // 后台拉取镜像中的实例（状态展示用）
    private static let pullingIds = HashSet<String>()

    public static func markPulling(id: String) {
        mutex.lock()
        pullingIds.add(id)
        mutex.unlock()
    }

    public static func clearPulling(id: String) {
        mutex.lock()
        pullingIds.remove(id)
        mutex.unlock()
    }

    public static func isPulling(id: String): Bool {
        mutex.lock()
        let v = pullingIds.contains(id)
        mutex.unlock()
        return v
    }

    /* 生成实例 ID：gp-<时间戳36进制><序号36进制>，短且基本有序 */
    public static func genId(): String {
        mutex.lock()
        idSeq += 1
        let seq = idSeq
        mutex.unlock()
        let ms = DateTime.now().toUnixTimeStamp().toMilliseconds()
        return "gp-" + ms.toString() + "-" + seq.toString()
    }

    public static func nowStr(): String {
        return DateTime.now().format("yyyy-MM-dd HH:mm:ss")
    }

    /* 创建实例：参数校验 -> 建目录 -> 落库 -> 拉镜像 -> 起容器 */
    public static func create(body: JsonObject): ?String {
        let gameKey = HttpUtil.str(body, "game", "")
        let tpl = match (Games.find(gameKey)) {
            case Some(t) => t
            case None => return Some("不支持的游戏类型: ${gameKey}")
        }
        let name = HttpUtil.str(body, "name", "").trimAscii()
        if (name == "") {
            return Some("实例名称不能为空")
        }
        let versionKey = HttpUtil.str(body, "version", "")
        // 先查静态版本表；未命中再按 "<loader>-<版本>" 动态解析（前端动态拉取的
        // 官方最新版本，如 paper-26.3 / fabric-26.2 / vanilla-26.3）
        let ver = match (tpl.findVersion(versionKey)) {
            case Some(v) => v
            case None =>
                let dash = idxOf(versionKey, "-")
                if (dash <= 0) {
                    return Some("不支持的版本: ${versionKey}")
                }
                let loader = versionKey[..dash]
                let verNum = versionKey[dash + 1..]
                if (verNum == "") {
                    return Some("不支持的版本: ${versionKey}")
                }
                match (loader) {
                    case "paper" => GameVersion(versionKey, "Paper ${verNum}", tpl.image, [("TYPE", "PAPER"), ("VERSION", verNum)])
                    case "fabric" => GameVersion(versionKey, "Fabric ${verNum}", tpl.image, [("TYPE", "FABRIC"), ("VERSION", verNum)])
                    case "vanilla" => GameVersion(versionKey, "原版 ${verNum}", tpl.image, [("TYPE", "VANILLA"), ("VERSION", verNum)])
                    case "forge" => GameVersion(versionKey, "Forge ${verNum}", tpl.image, [("TYPE", "FORGE"), ("VERSION", verNum)])
                    case _ => return Some("不支持的版本: ${versionKey}")
                }
        }
        // 端口：默认取模板第一个端口的主机侧，允许自定义（必须未被面板内其他实例占用）
        var portStr = HttpUtil.str(body, "port", "").trimAscii()
        if (portStr == "") {
            let first = tpl.ports[0]
            portStr = first[..idxOf(first, ":")]
        }
        for (c in portStr.toRuneArray()) {
            if (!(c >= r'0' && c <= r'9')) {
                return Some("端口只能是数字")
            }
        }
        let db = Store.data()
        for (ins in db.instances) {
            for (p in ins.ports) {
                let hostPart = p[..idxOf(p, ":")]
                if (hostPart == portStr) {
                    return Some("端口 ${portStr} 已被实例「${ins.name}」占用")
                }
            }
        }

        let ins = Instance()
        ins.id = genId()
        ins.name = name
        ins.game = tpl.key
        ins.version = ver.key
        ins.image = ver.image
        ins.dataDir = Paths.instanceDir(ins.id)
        ins.mountPath = tpl.mountPath
        for (p in tpl.ports) {
            let containerPart = p[idxOf(p, ":") + 1..]
            ins.ports.add("${portStr}:${containerPart}")
        }
        // 版本环境变量叠加模板基础变量
        for ((k, v) in tpl.baseEnv) {
            ins.env.add(k, v)
        }
        for ((k, v) in ver.env) {
            ins.env.add(k, v)
        }
        // 用户自定义环境变量
        match (body.get("extraEnv")) {
            case Some(v) =>
                if (HttpUtil.kindIs(v, JsonKind.JsObject)) {
                    for ((k, item) in v.asObject().getFields()) {
                        ins.extraEnv.add(k, Jsons.text(item))
                    }
                }
            case None => ()
        }
        ins.memoryMB = HttpUtil.int(body, "memoryMB", 2048)
        match (body.get("cpus")) {
            case Some(v) =>
                if (HttpUtil.kindIs(v, JsonKind.JsFloat)) {
                    ins.cpus = v.asFloat().getValue()
                } else if (HttpUtil.kindIs(v, JsonKind.JsInt)) {
                    ins.cpus = Float64.parse(v.asInt().getValue().toString())
                }
            case None => ()
        }
        ins.autoStart = HttpUtil.boolean(body, "autoStart", true)
        ins.useMesh = HttpUtil.boolean(body, "useMesh", false)
        ins.node = HttpUtil.str(body, "node", "local").trimAscii()
        // 校验节点存在
        var nodeOk = false
        for (n in Nodes.load()) {
            if (n.name == ins.node) {
                nodeOk = true
            }
        }
        if (!nodeOk) {
            ins.node = "local"
        }
        ins.createdAt = nowStr()

        if (!exists(ins.dataDir)) {
            Directory.create(ins.dataDir, recursive: true)
        }
        Store.update({ d => d.instances.add(ins) })

        // 拉镜像 + 启动放后台线程，创建接口立刻返回
        markPulling(ins.id)
        spawn {
            let pull = Docker.pull(ins.image, node: ins.node)
            clearPulling(ins.id)
            if (!pull.ok()) {
                println("[instance] ${ins.id} 拉取镜像失败: ${pull.stderr}")
            }
            let r = Docker.runInstance(ins)
            if (r.ok()) {
                ConsolePipe.attach(ins)
                println("[instance] ${ins.id} 已启动")
            } else {
                println("[instance] ${ins.id} 启动失败: ${r.stderr}")
            }
        }
        return None
    }

    /* 列表聚合：静态配置 + 实时状态 + 资源占用 */
    public static func listJson(): JsonArray {
        let arr = JsonArray()
        for (ins in Store.data().instances) {
            arr.add(oneJson(ins))
        }
        return arr
    }

    public static func oneJson(ins: Instance): JsonObject {
        var st = Docker.status(ins.containerName(), node: ins.node)
        if (st == "missing" && isPulling(ins.id)) {
            st = "pulling"
        }
        // 资源占用读 Monitor 缓存（30 秒粒度），docker stats 同步调用会阻塞 1~2 秒
        let (cpu, mem) = Monitor.latestStats(ins.id)
        let tpl = Games.find(ins.game)
        var icon = "📦"
        var title = ins.game
        match (tpl) {
            case Some(t) => icon = t.icon; title = t.title
            case None => ()
        }
        let portsArr = JsonArray()
        for (p in ins.ports) {
            portsArr.add(JsonString(p))
        }
        let op = Ops.get(ins.id)
        return Jsons.obj([
            ("id", JsonString(ins.id)),
            ("name", JsonString(ins.name)),
            ("operation", JsonString(op)),
            ("game", JsonString(ins.game)),
            ("gameTitle", JsonString(title)),
            ("icon", JsonString(icon)),
            ("version", JsonString(ins.version)),
            ("image", JsonString(ins.image)),
            ("status", JsonString(st)),
            ("node", JsonString(ins.node)),
            ("useMesh", JsonBool(ins.useMesh)),
            ("ports", portsArr),
            ("memoryMB", JsonInt(ins.memoryMB)),
            ("cpus", JsonFloat(ins.cpus)),
            ("autoStart", JsonBool(ins.autoStart)),
            ("createdAt", JsonString(ins.createdAt)),
            ("cpuPercent", JsonString(cpu)),
            ("memUsage", JsonString(mem))
        ])
    }

    public static func findOr404(ctx: HttpContext, id: String): ?Instance {
        match (Store.data().findInstance(id)) {
            case Some(ins) => return Some(ins)
            case None =>
                HttpUtil.fail(ctx, 404, "实例不存在")
                return None
        }
    }

    /* 删除实例：容器 + 数据 + 备份快照全部清理 */
    public static func remove(ins: Instance) {
        ConsolePipe.detach(ins.id)
        Docker.forceRemove(ins.containerName(), node: ins.node)
        Monitor.cleanup(ins.id)
        Store.update({ d =>
            d.instances.removeIf({ x => x.id == ins.id })
            d.tasks.removeIf({ t => t.instanceId == ins.id })
            d.records.removeIf({ r => r.instanceId == ins.id })
        })
        try {
            remove(ins.dataDir, recursive: true)
            remove(Paths.backupDir(ins.id), recursive: true)
            remove(Paths.snapshotDir(ins.id), recursive: true)
        } catch (_: Exception) {
            ()
        }
    }
}

/* ---------------- REST 路由 ---------------- */

public func registerInstanceRoutes(): Unit {
    /* 模板列表（创建向导用，登录即可看） */
    router.get("/api/v1/templates", { ctx, _ =>
        if (!Auth.guard(ctx)) {
            return
        }
        HttpUtil.ok(ctx, Games.listJson())
    })

    /* 实例列表（含实时状态） */
    router.get("/api/v1/instances", { ctx, _ =>
        if (!Auth.guard(ctx)) {
            return
        }
        HttpUtil.ok(ctx, Instances.listJson())
    })

    /* 创建实例 */
    router.post("/api/v1/instances", { ctx, _ =>
        if (!Auth.guard(ctx)) {
            return
        }
        let body = HttpUtil.bodyJson(ctx)
        match (Instances.create(body)) {
            case None => HttpUtil.okMsg(ctx, "实例创建中，镜像拉取完成后自动启动")
            case Some(err) => HttpUtil.fail(ctx, 2001, err)
        }
    })

    /* 实例详情 */
    router.get("/api/v1/instances/{id}", { ctx, md =>
        if (!Auth.guard(ctx)) {
            return
        }
        match (Instances.findOr404(ctx, md.matchString("id"))) {
            case Some(ins) => HttpUtil.ok(ctx, Instances.oneJson(ins))
            case None => ()
        }
    })

    /* 控制台日志 */
    router.get("/api/v1/instances/{id}/logs", { ctx, md =>
        if (!Auth.guard(ctx)) {
            return
        }
        match (Instances.findOr404(ctx, md.matchString("id"))) {
            case Some(ins) =>
                let q = ctx.request.form
                var tail = 200
                match (q.get("tail")) {
                    case Some(s) =>
                        try {
                            tail = Int64.parse(s)
                            if (tail > 2000 || tail < 1) {
                                tail = 200
                            }
                        } catch (_: Exception) {
                            tail = 200
                        }
                    case None => ()
                }
                HttpUtil.ok(ctx, Jsons.obj([("logs", JsonString(Docker.logs(ins.containerName(), tail)))]))
            case None => ()
        }
    })

    /* 发送控制台命令 */
    router.post("/api/v1/instances/{id}/command", { ctx, md =>
        if (!Auth.guard(ctx)) {
            return
        }
        match (Instances.findOr404(ctx, md.matchString("id"))) {
            case Some(ins) =>
                if (Docker.status(ins.containerName(), node: ins.node) != "running") {
                    HttpUtil.fail(ctx, 3005, "实例未在运行")
                    return
                }
                let body = HttpUtil.bodyJson(ctx)
                // 空回车是合法输入（确认交互菜单默认项），只拒绝未传 cmd 字段
                match (body.get("cmd")) {
                    case None =>
                        HttpUtil.fail(ctx, 3006, "缺少 cmd 字段")
                        return
                    case Some(_) => ()
                }
                let cmd = Jsons.text(body.get("cmd") ?? JsonString("")).trimAscii()
                let ok = ConsolePipe.send(ins, cmd)
                if (ok) {
                    HttpUtil.okMsg(ctx, "已发送")
                } else {
                    HttpUtil.fail(ctx, 3007, "发送失败：该游戏镜像可能不支持控制台输入")
                }
            case None => ()
        }
    })

    /* 修改设置（名称/内存/CPU/自启/extraEnv），需要重建容器生效 */
    router.put("/api/v1/instances/{id}", { ctx, md =>
        if (!Auth.guard(ctx)) {
            return
        }
        match (Instances.findOr404(ctx, md.matchString("id"))) {
            case Some(ins) =>
                let body = HttpUtil.bodyJson(ctx)
                Store.update({ d =>
                    match (d.findInstance(ins.id)) {
                        case Some(cur) =>
                            let newName = HttpUtil.str(body, "name", cur.name).trimAscii()
                            if (newName != "") {
                                cur.name = newName
                            }
                            cur.memoryMB = HttpUtil.int(body, "memoryMB", cur.memoryMB)
                            match (body.get("cpus")) {
                                case Some(v) =>
                                    if (HttpUtil.kindIs(v, JsonKind.JsFloat)) {
                                        cur.cpus = v.asFloat().getValue()
                                    } else if (HttpUtil.kindIs(v, JsonKind.JsInt)) {
                                        cur.cpus = Float64.parse(v.asInt().getValue().toString())
                                    }
                                case None => ()
                            }
                            cur.autoStart = HttpUtil.boolean(body, "autoStart", cur.autoStart)
                            match (body.get("extraEnv")) {
                                case Some(v) =>
                                    if (HttpUtil.kindIs(v, JsonKind.JsObject)) {
                                        cur.extraEnv = HashMap<String, String>()
                                        for ((k, item) in v.asObject().getFields()) {
                                            cur.extraEnv.add(k, Jsons.text(item))
                                        }
                                    }
                                case None => ()
                            }
                        case None => ()
                    }
                })
                // 需要重建容器才能应用资源限制/环境变量
                rebuild(ins.id)
                HttpUtil.okMsg(ctx, "设置已保存并重建容器")
            case None => ()
        }
    })

    /* 切换版本（数据保留，容器按新镜像/环境重建） */
    router.post("/api/v1/instances/{id}/change-version", { ctx, md =>
        if (!Auth.guard(ctx)) {
            return
        }
        match (Instances.findOr404(ctx, md.matchString("id"))) {
            case Some(ins) =>
                let body = HttpUtil.bodyJson(ctx)
                let versionKey = HttpUtil.str(body, "version", "")
                let tpl = match (Games.find(ins.game)) {
                    case Some(t) => t
                    case None => HttpUtil.fail(ctx, 500, "游戏模板缺失"); return
                }
                let ver = match (tpl.findVersion(versionKey)) {
                    case Some(v) => v
                    case None => HttpUtil.fail(ctx, 2002, "不支持的版本: ${versionKey}"); return
                }
                Store.update({ d =>
                    match (d.findInstance(ins.id)) {
                        case Some(cur) =>
                            cur.version = ver.key
                            cur.image = ver.image
                            // 基础变量重建：模板基础 + 版本变量 + 原用户自定义
                            let base = HashMap<String, String>()
                            for ((k, v) in tpl.baseEnv) {
                                base.add(k, v)
                            }
                            for ((k, v) in ver.env) {
                                base.add(k, v)
                            }
                            cur.env = base
                        case None => ()
                    }
                })
                spawn {
                    Docker.pull(ver.image)
                    rebuild(ins.id)
                }
                HttpUtil.okMsg(ctx, "版本切换中：拉取镜像后将自动重建容器（数据保留）")
            case None => ()
        }
    })
}

/* 重建容器：删除旧容器 -> run 新容器（数据在 bind mount，不受影响） */
public func rebuild(id: String): Unit {
    match (Store.data().findInstance(id)) {
        case Some(ins) =>
            Monitor.markUserAction(ins.id)
            ConsolePipe.detach(ins.id)
            Docker.forceRemove(ins.containerName(), node: ins.node)
            let r = Docker.runInstance(ins)
            if (r.ok()) {
                ConsolePipe.attach(ins)
            } else {
                println("[instance] 重建 ${ins.id} 失败: ${r.stderr}")
            }
        case None => ()
    }
}


func defaultName(s: String): String {
    if (s == "") {
        return "manual"
    }
    return s
}

/* 生命周期动作路由：必须最后注册（{action} 会吞掉同前缀的具体路径） */
public func registerLifecycleRoutes(): Unit {
    router.post("/api/v1/instances/{id}/{action}", { ctx, md =>
    if (!Auth.guard(ctx)) {
        return
    }
    let action = md.matchString("action")
    match (Instances.findOr404(ctx, md.matchString("id"))) {
        case Some(ins) =>
            match (action) {
                case "start" =>
                    if (!Docker.exists(ins.containerName(), node: ins.node)) {
                        // 容器丢失（宿主机清理/手动删除）：数据在 bind mount 完好，自动重建
                        Ops.runAsync(ins.id, "starting", { =>
                            let pull = Docker.pull(ins.image, node: ins.node)
                            if (!pull.ok()) {
                                println("[instance] ${ins.id} 拉取镜像失败: ${pull.stderr}")
                            }
                            let r = Docker.runInstance(ins)
                            if (r.ok()) {
                                ConsolePipe.attach(ins)
                                None
                            } else {
                                Some(r.stderr.trimAscii())
                            }
                        })
                        HttpUtil.okMsg(ctx, "容器已不存在，正在按原配置重建并启动（数据目录保留）")
                    } else {
                        let r = Docker.start(ins.containerName(), node: ins.node)
                        if (r.ok()) {
                            ConsolePipe.attach(ins)
                            HttpUtil.okMsg(ctx, "已启动")
                        } else {
                            HttpUtil.fail(ctx, 3002, r.stderr.trimAscii())
                        }
                    }
                case "stop" =>
                    Monitor.markUserAction(ins.id)
                    ConsolePipe.detach(ins.id)
                    Ops.runAsync(ins.id, "stopping", { =>
                        let r = Docker.stop(ins.containerName(), node: ins.node)
                        if (r.ok()) {
                            None
                        } else {
                            Some(r.stderr.trimAscii())
                        }
                    })
                    HttpUtil.okMsg(ctx, "停止指令已下发（优雅关服中，完成后状态自动刷新）")
                case "restart" =>
                    Monitor.markUserAction(ins.id)
                    ConsolePipe.detach(ins.id)
                    Ops.runAsync(ins.id, "restarting", { =>
                        let r = Docker.restart(ins.containerName(), node: ins.node)
                        if (r.ok()) {
                            ConsolePipe.attach(ins)
                            None
                        } else {
                            Some(r.stderr.trimAscii())
                        }
                    })
                    HttpUtil.okMsg(ctx, "重启指令已下发（优雅关服 + 重启，完成后状态自动刷新）")
                case "delete" =>
                    Monitor.markUserAction(ins.id)
                    match (Auth.current(ctx)) {
                        case Some(s) => Users.audit(s.username, "删除实例 ${ins.name}(${ins.id})")
                        case None => ()
                    }
                    Instances.remove(ins)
                    HttpUtil.okMsg(ctx, "已删除（含数据目录与备份）")
                case "backup" =>
                    let body = HttpUtil.bodyJson(ctx)
                    let bname = defaultName(HttpUtil.str(body, "name", "manual").trimAscii())
                    Ops.runAsync(ins.id, "backing-up", { =>
                        Backups.createBackup(ins, bname, false)
                    })
                    HttpUtil.okMsg(ctx, "备份任务已开始（完成后可在备份列表查看）")
                case "snapshot" =>
                    let body = HttpUtil.bodyJson(ctx)
                    let sname = defaultName(HttpUtil.str(body, "name", "manual").trimAscii())
                    Ops.runAsync(ins.id, "snapshotting", { =>
                        Backups.createSnapshot(ins, sname, false)
                    })
                    HttpUtil.okMsg(ctx, "快照任务已开始（完成后可在快照列表查看）")
                case _ =>
                    HttpUtil.fail(ctx, 404, "未知操作: ${action}")
            }
        case None => ()
    }
})

}
