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
