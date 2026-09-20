package gamepanel

/*
 * 备份与快照。
 * 概念区分（面板的核心差异化之一）：
 *   备份 backup   —— 整个实例数据目录打包 tar.gz，用于整体恢复/迁移
 *   快照 snapshot —— 只打包游戏存档目录（模板 savePaths），体积小、创建快，
 *                    用于"世界回档"：打了一晚上宝物没爆率，回快照重来
 * 恢复时都要求实例处于停止状态，恢复完成由用户手动启动。
 */

import stdx.net.http.*
import stdx.encoding.json.*
import std.process.*
import std.fs.*
import std.random.*
import std.sync.*
import std.time.*
import std.collection.*

/* 闭包不能捕获 var，计数放进引用对象 */
class Ref {
    public var n: Int64 = 0
}

public class Backups {
    /* 执行 tar 打包：把 dataDir 下的 paths 列表压缩到 outFile */
    private static func tar(dataDir: String, paths: ArrayList<String>, outFile: String): ?String {
        let args = ArrayList<String>(["-czf", outFile, "-C", dataDir])
        for (p in paths) {
            if (p == "." || p == "") {
                args.add(".")
            } else {
                args.add(p)
            }
        }
        let (code, _, err) = Process.runOutput("tar", args.toArray())
        if (code != 0) {
            return Some(String.fromUtf8(err).trimAscii())
        }
        return None
    }

    private static func fileSize(path: String): Int64 {
        try {
            return FileInfo(path).size
        } catch (_: Exception) {
            return 0
        }
    }

    private static func mkDir(path: String) {
        if (!exists(path)) {
            Directory.create(path, recursive: true)
        }
    }

    public static func nowMs(): Int64 {
        return DateTime.now().toUnixTimeStamp().toMilliseconds()
    }

    public static func genRecId(): String {
        let ms = nowMs()
        let r = Random(UInt64(ms))
        return "r-" + ms.toString() + "-" + r.nextInt64(9000).toString()
    }

    /* 创建备份（全量目录） */
    public static func createBackup(ins: Instance, name: String, auto: Bool): ?String {
        mkDir(Paths.backupDir(ins.id))
        let stamp = DateTime.now().format("yyyyMMdd-HHmmss")
        let fileName = "${stamp}-${name}.tar.gz"
        let outFile = Paths.backupDir(ins.id) + "/" + fileName
        let paths = ArrayList<String>(["."])
        match (tar(ins.dataDir, paths, outFile)) {
            case Some(err) => return Some("打包失败: ${err}")
            case None => ()
        }
        let rec = BackupRec()
        rec.id = genRecId()
        rec.instanceId = ins.id
        rec.kind = "backup"
        rec.name = name
        rec.file = relUnderRoot(outFile)
        rec.sizeBytes = fileSize(outFile)
        rec.auto = auto
        rec.createdAt = Instances.nowStr()
        Store.update({ d => d.records.add(rec) })
        return None
    }

    /* 创建快照（仅存档目录）。savePaths 为 ["."] 时退化为全量（如泰拉瑞亚）。 */
    public static func createSnapshot(ins: Instance, name: String, auto: Bool): ?String {
        mkDir(Paths.snapshotDir(ins.id))
        let tpl = Games.find(ins.game)
        let paths = ArrayList<String>()
        match (tpl) {
            case Some(t) =>
                for (p in t.savePaths) {
                    paths.add(p)
                }
            case None => paths.add(".")
        }
        if (paths.size == 0) {
            return Some("该游戏模板未定义存档路径，无法快照")
        }
        let stamp = DateTime.now().format("yyyyMMdd-HHmmss")
        let fileName = "${stamp}-${name}.tar.gz"
        let outFile = Paths.snapshotDir(ins.id) + "/" + fileName
        match (tar(ins.dataDir, paths, outFile)) {
            case Some(err) => return Some("打包失败: ${err}")
            case None => ()
        }
        let rec = BackupRec()
        rec.id = genRecId()
        rec.instanceId = ins.id
        rec.kind = "snapshot"
        rec.name = name
        rec.file = relUnderRoot(outFile)
        rec.sizeBytes = fileSize(outFile)
        rec.auto = auto
        rec.createdAt = Instances.nowStr()
        Store.update({ d => d.records.add(rec) })
        return None
    }

    /* 恢复：backup 清空数据目录后解压；snapshot 仅替换存档子目录 */
    public static func absPath(rec: BackupRec): String {
        return Config.dataRoot + "/" + rec.file
    }

    public static func restore(rec: BackupRec): ?String {
        let recFile = Backups.absPath(rec)
        if (!exists(recFile)) {
            return Some("归档文件不存在（可能已被清理）")
        }
        match (Store.data().findInstance(rec.instanceId)) {
            case Some(ins) =>
                let status = Docker.status(ins.containerName(), node: ins.node)
                if (status == "running" || status == "paused") {
                    return Some("请先停止实例再恢复")
                }
                // 恢复前自动留一份保护快照，防止恢复错档无法撤销
                let guard = createSnapshot(ins, "恢复前保护", false)
                match (guard) {
                    case Some(e) => println("[backup] 保护快照失败(继续恢复): ${e}")
                    case None => ()
                }
                let (code, _, err) = Process.runOutput("tar", ["-xzf", recFile, "-C", ins.dataDir])
                if (code != 0) {
                    return Some("解压失败: " + String.fromUtf8(err).trimAscii())
                }
                return None
            case None => return Some("实例不存在")
        }
    }

    /* 按保留份数清理：同类（backup/snapshot）保留最近 keepCount 份 */
    public static func prune(instanceId: String, kind: String, keepCount: Int64): Int64 {
        let counter = Ref()
        Store.update({ d =>
            let mine = ArrayList<BackupRec>()
            for (r in d.records) {
                if (r.instanceId == instanceId && r.kind == kind) {
                    mine.add(r)
                }
            }
            if (mine.size <= keepCount) {
                return
            }
            // 按创建时间升序排（文件名带时间戳，字典序即可）
            sortRecs(mine)
            let toRemove = mine.size - keepCount
            for (i in 0..toRemove) {
                let r = mine[i]
                try {
                    remove(Backups.absPath(r))
                } catch (_: Exception) {
                    ()
                }
                d.records.removeIf({ x => x.id == r.id })
                counter.n += 1
            }
        })
        return counter.n
    }

    private static func sortRecs(list: ArrayList<BackupRec>) {
        // 简单插入排序（数量小）
        for (i in 1..list.size) {
            let key = list[i]
            var j = i - 1
            while (j >= 0 && list[j].file > key.file) {
                list[j + 1] = list[j]
                j -= 1
            }
            list[j + 1] = key
        }
    }

    public static func recordsJson(instanceId: String, kind: String): JsonArray {
        let arr = JsonArray()
        for (r in Store.data().records) {
            if (r.instanceId == instanceId) {
                if (kind == "" || kind == "all" || kind == r.kind) {
                    arr.add(r.toJson())
                }
            }
        }
        return arr
    }
}

/* ---------------- REST 路由 ---------------- */

public func registerBackupRoutes(): Unit {
    /* 列表：?kind=backup|snapshot|all */
    router.get("/api/v1/instances/{id}/records", { ctx, md =>
        if (!Auth.guard(ctx)) {
            return
        }
        match (Instances.findOr404(ctx, md.matchString("id"))) {
            case Some(ins) =>
                var kind = "all"
                match (ctx.request.form.get("kind")) {
                    case Some(k) => kind = k
                    case None => ()
                }
                HttpUtil.ok(ctx, Backups.recordsJson(ins.id, kind))
            case None => ()
        }
    })

    /* 恢复 */
    router.post("/api/v1/records/{rid}/restore", { ctx, md =>
        if (!Auth.guard(ctx)) {
            return
        }
        match (Store.data().findRecord(md.matchString("rid"))) {
            case Some(rec) =>
                // 前置校验同步做（给出明确错误），解压放后台
                let recFile = Backups.absPath(rec)
                if (!exists(recFile)) {
                    HttpUtil.fail(ctx, 4002, "归档文件不存在")
                    return
                }
                var st = ""
                match (Store.data().findInstance(rec.instanceId)) {
                    case Some(ins) => st = Docker.status(ins.containerName(), node: ins.node)
                    case None => HttpUtil.fail(ctx, 404, "实例不存在"); return
                }
                if (st == "running" || st == "paused") {
                    HttpUtil.fail(ctx, 4002, "请先停止实例再恢复")
                    return
                }
                match (Auth.current(ctx)) {
                    case Some(s) => Users.audit(s.username, "恢复${rec.kind} ${rec.name} -> ${rec.instanceId}")
                    case None => ()
                }
                Ops.runAsync(rec.instanceId, "restoring", { =>
                    Backups.restore(rec)
                })
                HttpUtil.okMsg(ctx, "恢复任务已开始（自动先做保护快照，完成后可启动实例）")
            case None => HttpUtil.fail(ctx, 404, "记录不存在")
        }
    })

    /* 下载归档 */
    router.get("/api/v1/records/{rid}/download", { ctx, md =>
        if (!Auth.guard(ctx)) {
            return
        }
        match (Store.data().findRecord(md.matchString("rid"))) {
            case Some(rec) =>
                let recFile = Backups.absPath(rec)
                if (!exists(recFile)) {
                    HttpUtil.fail(ctx, 404, "归档文件不存在")
                    return
                }
                try {
                    let name = lastSeg(recFile)
                    ctx.responseBuilder.status(200)
                        .header("Content-Type", "application/octet-stream")
                        .header("Content-Disposition", "attachment; filename=\"${name}\"")
                        .body(File.readFrom(recFile))
                } catch (e: Exception) {
                    HttpUtil.fail(ctx, 4002, "下载失败: ${e.message}")
                }
            case None => HttpUtil.fail(ctx, 404, "记录不存在")
        }
    })

    /* 删除归档 */
    router.delete("/api/v1/records/{rid}", { ctx, md =>
        if (!Auth.guard(ctx)) {
            return
        }
        match (Store.data().findRecord(md.matchString("rid"))) {
            case Some(rec) =>
                match (Auth.current(ctx)) {
                    case Some(s) => Users.audit(s.username, "删除${rec.kind} ${rec.name}")
                    case None => ()
                }
                try {
                    remove(Backups.absPath(rec))
                } catch (_: Exception) {
                    ()
                }
                Store.update({ d => d.records.removeIf({ x => x.id == rec.id }) })
                HttpUtil.okMsg(ctx, "已删除")
            case None => HttpUtil.fail(ctx, 404, "记录不存在")
        }
    })
}


/* 绝对路径 -> dataRoot 下的相对路径，保证数据目录整体迁移后归档仍可用 */
func relUnderRoot(abs: String): String {
    let root = Config.dataRoot
    if (abs.startsWith(root + "/")) {
        return abs[root.size + 1..]
    }
    return abs
}

func lastSeg(path: String): String {
    let slash = lastIdxOf(path, "/")
    if (slash >= 0) {
        return path[slash + 1..]
    }
    return path
}
