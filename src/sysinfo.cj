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
    let s = runShell("df", ["-B1", "--output=avail", path])
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
            ("diskAvailGB", JsonFloat(Float64.parse(diskAvailBytes(Config.dataRoot).toString()) / 1073741824.0))
        ]))
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
