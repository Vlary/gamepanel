package gamepanel

/*
 * 系统信息与静态资源服务。
 * overview 聚合：实例状态 + Docker 状态 + 数据目录磁盘占用。
 * 静态服务：面板前端（web/ 目录）由后端直接提供，单二进制部署，无需 nginx。
 */

import stdx.net.http.*
import stdx.encoding.json.*
import std.process.*
import std.convert.*
import std.fs.*
import std.collection.*

func runShell(bin: String, args: Array<String>): String {
    let (code, out, _) = Process.runOutput(bin, args)
    if (code != 0) {
        return ""
    }
    return String.fromUtf8(out).trimAscii()
}

/* 目录磁盘占用：du -sk */
func dirSizeKB(path: String): Int64 {
    let s = runShell("du", ["-sk", path])
    if (s == "") {
        return 0
    }
    let parts = s.split("\t")
    try {
        return Int64.parse(parts[0])
    } catch (_: Exception) {
        return 0
    }
}

/* 磁盘可用空间：df -B1 输出 Avail 列 */
func diskAvailBytes(path: String): Int64 {
    return dfColumn(path, "avail")
}

/* 磁盘总容量：df -B1 输出 size 列（df 无 total 字段名） */
func diskTotalBytes(path: String): Int64 {
    return dfColumn(path, "size")
}

func dfColumn(path: String, col: String): Int64 {
    let s = runShell("df", ["-B1", "--output=" + col, path])
    if (s == "") {
        return 0
    }
    let lines = s.split("\n")
    if (lines.size < 2) {
        return 0
    }
    try {
        return Int64.parse(lines[1].trimAscii())
    } catch (_: Exception) {
        return 0
    }
}

let dockerVerCache = HashMap<String, (String, Int64)>()

func dockerVersionCached(): String {
    let now = Auth.nowSec()
    match (dockerVerCache.get("v")) {
        case Some((ver, at)) =>
            if (now - at < 300) {
                return ver
            }
        case None => ()
    }
    let v = Docker.version()
    dockerVerCache.add("v", (v, now))
    return v
}

public func registerSystemRoutes(): Unit {
    /* 总览：面板首页一次性拉全 */
    router.get("/api/v1/overview", { ctx, _ =>
        if (!Auth.guard(ctx)) {
            return
        }
        let dockerVer = dockerVersionCached()
        var runningCount: Int64 = 0
        let list = Instances.listJson()
        for (v in list.getItems()) {
            if (Jsons.text((v.asObject().get("status")) ?? JsonString("")) == "running") {
                runningCount += 1
            }
        }
        HttpUtil.ok(ctx, Jsons.obj([
            ("dockerVersion", JsonString(dockerVer)),
            ("dockerOk", JsonBool(dockerVer != "")),
            ("instanceCount", JsonInt(list.size())),
            ("runningCount", JsonInt(runningCount)),
            ("dataDir", JsonString(Config.dataRoot)),
            ("dataUsedMB", JsonInt(Monitor.dataUsedKBNow() / 1024)),
            ("diskAvailGB", JsonFloat(Float64.parse(diskAvailBytes(Config.dataRoot).toString()) / 1073741824.0)),
            ("diskTotalGB", JsonFloat(Float64.parse(diskTotalBytes(Config.dataRoot).toString()) / 1073741824.0))
        ]))
    })

    /* 端口预检：创建向导即时校验宿主端口可用性
       - 面板内实例端口对比（全部节点）
       - 本机系统级 LISTEN 检测（/proc/net/tcp + tcp6，零依赖且无权限要求）
       远端节点的系统级占用无法读 /proc，仅做实例对比并在响应中说明 */
    router.get("/api/v1/port-check", { ctx, md =>
        if (!Auth.guard(ctx)) {
            return
        }
        let portStr = queryParam(ctx, "port")
        var port: Int64 = -1
        try {
            port = Int64.parse(portStr)
        } catch (_: Exception) {
            HttpUtil.fail(ctx, 2101, "端口格式错误")
            return
        }
        if (port < 1 || port > 65535) {
            HttpUtil.fail(ctx, 2102, "端口范围 1-65535")
            return
        }
        var byInstance = ""
        for (ins in Store.data().instances) {
            for (p in ins.ports) {
                let host = p.split(":")[0]
                try {
                    if (Int64.parse(host) == port) {
                        byInstance = ins.name
                        break
                    }
                } catch (_: Exception) {
                    ()
                }
            }
            if (byInstance != "") {
                break
            }
        }
        let sysInUse = listeningPorts().contains(port)
        HttpUtil.ok(ctx, Jsons.obj([
            ("port", JsonInt(port)),
            ("available", JsonBool(byInstance == "" && !sysInUse)),
            ("byInstance", JsonString(byInstance)),
            ("systemInUse", JsonBool(sysInUse))
        ]))
    })
}

/* /proc/net/tcp(6) 的 LISTEN 端口集合（本机），字节级解析 */
func listeningPorts(): HashSet<Int64> {
    let out = HashSet<Int64>()
    for (f in ["/proc/net/tcp", "/proc/net/tcp6"]) {
        if (!exists(f)) {
            continue
        }
        let text = String.fromUtf8(File.readFrom(f))
        for (line in text.split("\n")) {
            // 行格式: "sl local_address rem_address st ..."，空白分隔
            let cols = splitWs(line)
            if (cols.size < 4) {
                continue
            }
            // st == 0A 表示 LISTEN
            if (cols[3] != "0A") {
                continue
            }
            // local_address 形如 00000000:1F90（端口为十六进制）
            let local = cols[1]
            let colon = idxOf(local, ":")
            if (colon < 0) {
                continue
            }
            let p = parseHex(local[colon + 1..])
            if (p >= 0) {
                out.add(p)
            }
        }
    }
    return out
}

/* 十六进制字符串 -> 非负整数，非法返回 -1 */
func parseHex(s: String): Int64 {
    if (s == "") {
        return -1
    }
    var v: Int64 = 0
    for (b in s.toArray()) {
        let d = hexVal(b)
        if (d < 0) {
            return -1
        }
        v = v * 16 + d
    }
    return v
}

/* 按任意空白切分（/proc 输出连续空格，String.split 字面量分隔会产生空段） */
func splitWs(line: String): ArrayList<String> {
    let out = ArrayList<String>()
    let bytes = line.toArray()
    var start = -1
    var i = 0
    while (i <= bytes.size) {
        let isWs = i == bytes.size || bytes[i] == 32 || bytes[i] == 9
        if (isWs) {
            if (start >= 0) {
                out.add(String.fromUtf8(bytes[start..i]))
                start = -1
            }
        } else if (start < 0) {
            start = i
        }
        i += 1
    }
    return out
}

/* ---------------- 运维诊断 ---------------- */

/*
 * 数据目录明细：按实例目录 + 归档/监控等占用分解（admin）
 * du 逐目录执行，目录多时秒级耗时，前端加载态兜底
 */
func storageJson(): JsonObject {
    let insts = JsonArray()
    var instKB: Int64 = 0
    for (ins in Store.data().instances) {
        let kb = dirSizeKB(ins.dataDir)
        instKB += kb
        insts.add(Jsons.obj([
            ("id", JsonString(ins.id)),
            ("name", JsonString(ins.name)),
            ("game", JsonString(ins.game)),
            ("sizeKB", JsonInt(kb))
        ]))
    }
    let root = Config.dataRoot
    func sub(name: String): Int64 {
        let p = root + "/" + name
        if (exists(p)) {
            return dirSizeKB(p)
        }
        return 0
    }
    let backupsKB = sub("backups")
    let snapshotsKB = sub("snapshots")
    var metricsKB: Int64 = 0
    if (exists(root + "/metrics.json")) {
        metricsKB = dirSizeKB(root + "/metrics.json")
    }
    let totalKB = dirSizeKB(root)
    return Jsons.obj([
        ("totalKB", JsonInt(totalKB)),
        ("instances", insts),
        ("instancesKB", JsonInt(instKB)),
        ("backupsKB", JsonInt(backupsKB)),
        ("snapshotsKB", JsonInt(snapshotsKB)),
        ("metricsKB", JsonInt(metricsKB)),
        ("otherKB", JsonInt(totalKB - instKB - backupsKB - snapshotsKB - metricsKB))
    ])
}

/*
 * 一键健康自检（admin）：Docker/磁盘/端口冲突/关键文件/TUN，返回检查项数组
 */
func healthReportJson(): JsonArray {
    let arr = JsonArray()
    func item(name: String, ok: Bool, detail: String) {
        arr.add(Jsons.obj([
            ("item", JsonString(name)),
            ("ok", JsonBool(ok)),
            ("detail", JsonString(detail))
        ]))
    }
    // 1. Docker 可用
    let dv = dockerVersionCached()
    item("Docker 守护进程", dv != "", if (dv != "") { "版本 ${dv}" } else { "docker 命令不可用或守护进程未运行" })
    // 2. 磁盘余量（<5GB 警告）
    let availGB = Float64.parse(diskAvailBytes(Config.dataRoot).toString()) / 1073741824.0
    let availTxt = "${Int64(availGB)} GB"
    item("磁盘余量", availGB >= 5.0, availTxt + (if (availGB < 5.0) { "（不足 5GB，备份可能失败）" } else { "" }))
    // 3. 实例端口冲突（同宿主端口被多个实例声明）
    let portMap = HashMap<String, Int64>()
    for (ins in Store.data().instances) {
        if (ins.ports.size > 0) {
            portMap.add(ins.ports[0].split(":")[0], (portMap.get(ins.ports[0].split(":")[0]) ?? 0) + 1)
        }
    }
    var dupPorts = ArrayList<String>()
    for ((port, cnt) in portMap) {
        if (cnt > 1) {
            dupPorts.add(port)
        }
    }
    item("端口冲突", dupPorts.size == 0, if (dupPorts.size == 0) { "无重复声明" } else { "重复端口: " + stringJoin(dupPorts, ", ") })
    // 4. 运行中实例的容器实际状态
    var runningCnt: Int64 = 0
    for (ins in Store.data().instances) {
        if (Docker.status(ins.containerName(), node: ins.node) == "running") {
            runningCnt += 1
        }
    }
    item("实例容器", true, "运行中 ${runningCnt} / 共 ${Store.data().instances.size}")
    // 5. 数据目录可写
    var writable = false
    try {
        let probe = Config.dataRoot + "/.gp-probe"
        File.writeTo(probe, "ok".toArray())
        writable = exists(probe)
        if (writable) {
            try {
                remove(probe)
            } catch (_: Exception) {
                ()
            }
        }
    } catch (_: Exception) {
        writable = false
    }
    item("数据目录可写", writable, if (writable) { Config.dataRoot } else { "${Config.dataRoot} 无法写入" })
    // 6. TUN 设备（组网依赖）
    item("TUN 设备", exists("/dev/net/tun"), if (exists("/dev/net/tun")) { "/dev/net/tun 存在（EasyTier 可用 TUN 模式）" } else { "缺失，EasyTier 将降级 --no-tun" })
    // 7. 计划任务健康
    var enabledCnt: Int64 = 0
    for (t in Store.data().tasks) {
        if (t.enabled) {
            enabledCnt += 1
        }
    }
    item("计划任务", true, "启用 ${enabledCnt} / 共 ${Store.data().tasks.size}")
    return arr
}

func stringJoin(list: ArrayList<String>, sep: String): String {
    let sb = StringBuilder()
    var first = true
    for (x in list) {
        if (!first) {
            sb.append(sep)
        }
        sb.append(x)
        first = false
    }
    return sb.toString()
}

public func registerDiagRoutes(): Unit {
    router.get("/api/v1/storage", { ctx, _ =>
        if (!Auth.guard(ctx) || !Auth.allowAdmin(ctx)) {
            return
        }
        HttpUtil.ok(ctx, storageJson())
    })

    router.get("/api/v1/health-report", { ctx, _ =>
        if (!Auth.guard(ctx) || !Auth.allowAdmin(ctx)) {
            return
        }
        HttpUtil.ok(ctx, healthReportJson())
    })
}

/* ---------------- 静态资源 ---------------- */

func mimeOf(name: String): String {
    // 取最后一个点之后的扩展名
    let dot = lastIdxOf(name, ".")
    if (dot < 0) {
        return "application/octet-stream"
    }
    let ext = name[dot + 1..].toAsciiLower()
    match (ext) {
        case "html" => return "text/html; charset=utf-8"
        case "css" => return "text/css; charset=utf-8"
        case "js" => return "application/javascript; charset=utf-8"
        case "json" => return "application/json; charset=utf-8"
        case "svg" => return "image/svg+xml"
        case "png" => return "image/png"
        case "jpg" => return "image/jpeg"
        case "ico" => return "image/x-icon"
        case "woff2" => return "font/woff2"
        case _ => return "application/octet-stream"
    }
}

func registerStaticRoutes(webRoot: String): Unit {
    /* 首页 */
    router.get("/", { ctx, _ =>
        serveFile(ctx, webRoot + "/index.html")
    })
    /* 静态资源 /s/css/style.css 形式 */
    router.get("/s/{rest...}", { ctx, md =>
        let rest = md.matchString("rest")
        serveFile(ctx, webRoot + "/" + rest)
    })
}

func serveFile(ctx: HttpContext, path: String) {
    try {
        if (!exists(path)) {
            notFound(ctx)
            return
        }
        let bytes = File.readFrom(path)
        ctx.responseBuilder.status(200)
            .header("Content-Type", mimeOf(path))
            .header("Cache-Control", "no-cache")
            .body(bytes)
    } catch (_: Exception) {
        notFound(ctx)
    }
}
