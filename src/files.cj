package gamepanel

/*
 * 实例文件管理器：浏览 / 在线编辑 / 上传 / 下载 / 删除 / 重命名 / 新建目录。
 * 安全规则：所有路径先 canonicalize，必须落在实例数据目录内，阻断 ../ 逃逸。
 * 上传采用 PUT 原始字节（前端 fetch 直接发文件内容），避免解析 multipart。
 */

import stdx.net.http.*
import stdx.encoding.json.*
import std.fs.*
import std.process.*
import std.collection.*

func lastIdxOf(s: String, sub: String): Int64 {
    let subArr = sub.toArray()
    let sArr = s.toArray()
    if (subArr.size == 0 || sArr.size < subArr.size) {
        return -1
    }
    var i = sArr.size - subArr.size
    while (i >= 0) {
        var hit = true
        for (j in 0..subArr.size) {
            if (sArr[i + j] != subArr[j]) {
                hit = false
                break
            }
        }
        if (hit) {
            return i
        }
        i -= 1
    }
    return -1
}

public class FileManager {
    /* 路径安全拼接：sub 必须是相对路径；返回绝对路径或 None（越界/逃逸）。
       已存在的目标用 canonicalize 结果校验（可挡符号链接逃逸）；
       不存在的目标（新建文件）校验其父目录后返回拼接路径。 */
    public static func safeJoin(base: String, sub: String): ?String {
        var rel = sub
        while (rel.startsWith("/")) {
            rel = rel[1..]
        }
        let baseC = canonicalize(base).toString()
        if (rel == "" || rel == ".") {
            return Some(baseC)
        }
        let joined = base + "/" + rel
        try {
            let c = canonicalize(joined).toString()
            if (c == baseC || c.startsWith(baseC + "/")) {
                return Some(c)
            }
            return None
        } catch (_: Exception) {
            let slash = lastIdxOf(joined, "/")
            if (slash <= 0) {
                return None
            }
            let parent = joined[..slash]
            try {
                let pc = canonicalize(parent).toString()
                if (pc == baseC || pc.startsWith(baseC + "/")) {
                    return Some(joined)
                }
                return None
            } catch (_: Exception) {
                return None
            }
        }
    }

    public static func listJson(dataDir: String, rel: String): JsonObject {
        let dir = match (safeJoin(dataDir, rel)) {
            case Some(p) => p
            case None => return Jsons.obj([("error", JsonString("非法路径"))])
        }
        let files = JsonArray()
        let dirs = JsonArray()
        try {
            for (fi in Directory.readFrom(dir)) {
                let item = Jsons.obj([
                    ("name", JsonString(fi.name)),
                    ("isDir", JsonBool(fi.isDirectory())),
                    ("size", JsonInt(fi.size))
                ])
                if (fi.isDirectory()) {
                    dirs.add(item)
                } else {
                    files.add(item)
                }
            }
        } catch (e: Exception) {
            return Jsons.obj([("error", JsonString("读取目录失败: ${e.message}"))])
        }
        return Jsons.obj([("dirs", dirs), ("files", files)])
    }
}

/* ---------------- REST 路由 ---------------- */

public func registerFileRoutes(): Unit {
    /* 目录列表 */
    router.get("/api/v1/instances/{id}/files", { ctx, md =>
        if (!Auth.guard(ctx)) {
            return
        }
        match (Instances.findOr404(ctx, md.matchString("id"))) {
            case Some(ins) =>
                let rel = ctx.request.form.get("path") ?? ""
                HttpUtil.ok(ctx, FileManager.listJson(ins.dataDir, rel))
            case None => ()
        }
    })

    /* 读取文本文件（<= 2MB） */
    router.get("/api/v1/instances/{id}/file", { ctx, md =>
        if (!Auth.guard(ctx)) {
            return
        }
        match (Instances.findOr404(ctx, md.matchString("id"))) {
            case Some(ins) =>
                let rel = ctx.request.form.get("path") ?? ""
                match (FileManager.safeJoin(ins.dataDir, rel)) {
                    case Some(p) =>
                        try {
                            if (!exists(p)) {
                                HttpUtil.fail(ctx, 404, "文件不存在")
                                return
                            }
                            let bytes = File.readFrom(p)
                            if (bytes.size > 2 * 1024 * 1024) {
                                HttpUtil.fail(ctx, 4101, "文件超过 2MB，请下载后编辑")
                                return
                            }
                            HttpUtil.raw(ctx, 200, "text/plain; charset=utf-8", String.fromUtf8(bytes))
                        } catch (e: Exception) {
                            HttpUtil.fail(ctx, 4102, "读取失败: ${e.message}")
                        }
                    case None => HttpUtil.fail(ctx, 4103, "非法路径")
                }
            case None => ()
        }
    })

    /* 保存文本 / 上传原始字节：PUT body 即文件内容，query: path=name（相对当前目录） */
    router.put("/api/v1/instances/{id}/file", { ctx, md =>
        if (!Auth.guard(ctx)) {
            return
        }
        match (Instances.findOr404(ctx, md.matchString("id"))) {
            case Some(ins) =>
                let rel = queryParam(ctx, "path")
                if (rel == "" || rel == "/") {
                    HttpUtil.fail(ctx, 4104, "缺少 path 参数")
                    return
                }
                match (FileManager.safeJoin(ins.dataDir, rel)) {
                    case Some(p) =>
                        try {
                            File.writeTo(p, HttpUtil.readBody(ctx).toArray())
                            HttpUtil.okMsg(ctx, "已保存")
                        } catch (e: Exception) {
                            HttpUtil.fail(ctx, 4105, "写入失败: ${e.message}")
                        }
                    case None => HttpUtil.fail(ctx, 4103, "非法路径")
                }
            case None => ()
        }
    })

    /* 下载文件 */
    router.get("/api/v1/instances/{id}/download", { ctx, md =>
        if (!Auth.guard(ctx)) {
            return
        }
        match (Instances.findOr404(ctx, md.matchString("id"))) {
            case Some(ins) =>
                let rel = ctx.request.form.get("path") ?? ""
                match (FileManager.safeJoin(ins.dataDir, rel)) {
                    case Some(p) =>
                        try {
                            HttpUtil.rawBytes(ctx, 200, "application/octet-stream", File.readFrom(p))
                        } catch (e: Exception) {
                            HttpUtil.fail(ctx, 4106, "下载失败: ${e.message}")
                        }
                    case None => HttpUtil.fail(ctx, 4103, "非法路径")
                }
            case None => ()
        }
    })

    /* 文件操作：mkdir / delete / rename */
    router.post("/api/v1/instances/{id}/file-action", { ctx, md =>
        if (!Auth.guard(ctx)) {
            return
        }
        match (Instances.findOr404(ctx, md.matchString("id"))) {
            case Some(ins) =>
                let body = HttpUtil.bodyJson(ctx)
                let action = HttpUtil.str(body, "action", "")
                let rel = HttpUtil.str(body, "path", "")
                match (FileManager.safeJoin(ins.dataDir, rel)) {
                    case Some(p) =>
                        try {
                            match (action) {
                                case "mkdir" =>
                                    if (!exists(p)) {
                                        Directory.create(p, recursive: true)
                                    }
                                    HttpUtil.okMsg(ctx, "已创建")
                                case "delete" =>
                                    if (exists(p)) {
                                        remove(p, recursive: true)
                                    }
                                    HttpUtil.okMsg(ctx, "已删除")
                                case "extract" =>
                                    if (!exists(p)) {
                                        HttpUtil.fail(ctx, 4109, "文件不存在")
                                        return
                                    }
                                    // 解压到压缩包所在目录
                                    let slashP = lastIdxOf(p, "/")
                                    let dirP = p[..slashP]
                                    let lower = p.toAsciiLower()
                                    var toolErr: ?String = None
                                    if (lower.endsWith(".zip")) {
                                        let (code, _, e) = Process.runOutput("unzip", ["-o", "-q", p, "-d", dirP])
                                        if (code != 0) {
                                            toolErr = Some(String.fromUtf8(e).trimAscii())
                                        }
                                    } else if (lower.endsWith(".tar.gz") || lower.endsWith(".tgz") || lower.endsWith(".tar")) {
                                        let (code, _, e) = Process.runOutput("tar", ["-xf", p, "-C", dirP])
                                        if (code != 0) {
                                            toolErr = Some(String.fromUtf8(e).trimAscii())
                                        }
                                    } else {
                                        HttpUtil.fail(ctx, 4110, "仅支持 .zip / .tar.gz / .tgz / .tar")
                                        return
                                    }
                                    match (toolErr) {
                                        case Some(e) => HttpUtil.fail(ctx, 4111, "解压失败: ${e}（zip 需要宿主机安装 unzip）")
                                        case None => HttpUtil.okMsg(ctx, "解压完成")
                                    }
                                case "rename" =>
                                    let newName = HttpUtil.str(body, "newName", "")
                                    if (newName == "") {
                                        HttpUtil.fail(ctx, 4107, "newName 不能为空")
                                        return
                                    }
                                    let parentEnd = lastIdxOf(p, "/")
                                    let parent = p[..parentEnd]
                                    rename(p, to: parent + "/" + newName)
                                    HttpUtil.okMsg(ctx, "已重命名")
                                case _ => HttpUtil.fail(ctx, 404, "未知操作: ${action}")
                            }
                        } catch (e: Exception) {
                            HttpUtil.fail(ctx, 4108, "操作失败: ${e.message}")
                        }
                    case None => HttpUtil.fail(ctx, 4103, "非法路径")
                }
            case None => ()
        }
    })
}


/* PUT 请求的 query 参数手动解析（request.form 对 PUT 不解析 query） */
func queryParam(ctx: HttpContext, key: String): String {
    match (ctx.request.url.query) {
        case Some(q) =>
            for (pair in q.split("&")) {
                let kv = pair.split("=")
                if (kv.size == 2 && kv[0] == key) {
                    return percentDecode(kv[1])
                }
            }
        case None => ()
    }
    return ""
}


/* 百分号解码：%XX -> 字节，其余原样（URL.decodeComponent 对未编码文本行为异常，自实现） */
func percentDecode(s: String): String {
    let bytes = s.toArray()
    let out = ArrayList<Byte>()
    var i = 0
    while (i < bytes.size) {
        if (bytes[i] == 37 && i + 2 < bytes.size) {   // '%' 后跟两位十六进制
            let hi = hexVal(bytes[i + 1])
            let lo = hexVal(bytes[i + 2])
            if (hi >= 0 && lo >= 0) {
                out.add(UInt8(hi * 16 + lo))
                i += 3
                continue
            }
        }
        out.add(bytes[i])
        i += 1
    }
    let arr = Array<Byte>(out.size, repeat: 0)
    for (j in 0..out.size) {
        arr[j] = out[j]
    }
    return String.fromUtf8(arr)
}

func hexVal(b: Byte): Int64 {
    if (b >= 48 && b <= 57) {
        return Int64(b) - 48
    }
    if (b >= 65 && b <= 70) {
        return Int64(b) - 55
    }
    if (b >= 97 && b <= 102) {
        return Int64(b) - 87
    }
    return -1
}
