package gamepanel

/*
 * Mod 管理：
 *  1. 本地 mods 目录浏览/删除/上传/启用禁用（.disabled 后缀切换）
 *  2. Modrinth 市场集成：搜索按实例的游戏版本+加载器过滤，一键安装
 * Modrinth 请求经宿主 curl 转发（stdx HTTP 客户端会对 URL 预编码字符二次编码，
 * facets 无法传递；curl 亦自动处理重定向下载）。
 */

import stdx.net.http.*
import stdx.encoding.json.*
import std.fs.*
import std.process.*
import std.convert.*
import std.collection.*

public class Modrinth {
    /* curl GET 文本 */
    static func curlGet(url: String): ?String {
        let (code, out, err) = Process.runOutput("curl",
            ["-sS", "--max-time", "25", "-H", "User-Agent: gamepanel/1.0", url])
        if (code != 0) {
            println("[modrinth] curl 失败(${code}): ${String.fromUtf8(err).trimAscii()}")
            return None
        }
        return Some(String.fromUtf8(out))
    }

    static func curlGetJson(url: String): ?JsonValue {
        match (curlGet(url)) {
            case Some(text) =>
                try {
                    return Some(JsonValue.fromStr(text))
                } catch (_: Exception) {
                    return None
                }
            case None => return None
        }
    }

    static func getJson(url: String): ?JsonValue {
        match (curlGet(url)) {
            case Some(text) =>
                try {
                    return Some(JsonValue.fromStr(text))
                } catch (e: Exception) {
                    println("[modrinth] JSON 解析失败: ${e.message}")
                    return None
                }
            case None => return None
        }
    }

    /* 手动百分号编码（避免依赖 stdx URL 编码的边界行为） */
    static func urlEnc(s: String): String {
        let hex = "0123456789ABCDEF"
        let sb = StringBuilder()
        for (b in s.toArray()) {
            let c = Int64(b)
            let safe = (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) ||
                c == 45 || c == 46 || c == 95 || c == 126
            if (safe) {
                sb.append(String.fromUtf8([b]))
            } else {
                sb.append("%")
                sb.append(hex[c / 16..c / 16 + 1])
                sb.append(hex[c % 16..c % 16 + 1])
            }
        }
        return sb.toString()
    }

    /* 解析版本 key -> (MC 版本, 加载器)。key 形如 paper-1.20.1 / vanilla-1.21 / forge-1.20 */
    public static func parseMcVersion(versionKey: String): (String, String) {
        let dash = idxOf(versionKey, "-")
        if (dash <= 0) {
            return ("", "")
        }
        return (versionKey[dash + 1..], versionKey[..dash])
    }

    /* 搜索：Minecraft 实例按 MC 版本 + 加载器过滤。
       注意：Modrinth 的版本 facet 需要具体到 patch 位（1.20.1 有效、1.20 无效），
       因此版本取自实例的 VERSION 环境变量；Paper/Vanilla 属插件生态（categories:paper），
       Fabric/Forge 属 Mod 生态（categories:<loader>）。 */
    public static func search(query: String, ins: Instance): ?JsonValue {
        var q = query
        if (q == "") {
            q = "*"
        }
        var url = "https://api.modrinth.com/v2/search?query=" + urlEnc(q) + "&limit=20"
        if (ins.game == "minecraft") {
            let (mc, loader) = parseMcVersion(ins.version)
            let ver = ins.env.get("VERSION") ?? mc
            if (ver != "" && loader != "") {
                var category = loader
                if (loader == "paper" || loader == "vanilla") {
                    category = "paper"   // 插件生态
                }
                let facets = "[[\"versions:${ver}\"],[\"categories:${category}\"]]"
                url = url + "&facets=" + urlEnc(facets)
            }
        }
        return getJson(url)
    }

    /* 项目版本列表 */
    public static func versions(projectId: String): ?JsonValue {
        return getJson("https://api.modrinth.com/v2/project/${projectId}/version")
    }

    /* 下载（curl -L 自动跟随重定向） */
    public static func download(url: String, destFile: String): ?String {
        let (code, _, err) = Process.runOutput("curl",
            ["-sSL", "--max-time", "180", "-H", "User-Agent: gamepanel/1.0", "-o", destFile, url])
        if (code != 0) {
            var msg = String.fromUtf8(err).trimAscii()
            if (msg == "") {
                msg = "HTTP 请求失败"
            }
            return Some("下载失败: ${msg}")
        }
        return None
    }
}

/* ---------------- REST 路由 ---------------- */

public func registerModRoutes(): Unit {
    /* mods 目录列表 */
    router.get("/api/v1/instances/{id}/mods", { ctx, md =>
        if (!Auth.guard(ctx)) {
            return
        }
        match (Instances.findOr404(ctx, md.matchString("id"))) {
            case Some(ins) =>
                let fullDir = ins.dataDir + "/" + modsDirOf(ins)
                if (!exists(ins.dataDir)) {
                    HttpUtil.fail(ctx, 4201, "实例数据目录不存在")
                    return
                }
                if (!exists(fullDir)) {
                    Directory.create(fullDir)
                }
                HttpUtil.ok(ctx, FileManager.listJson(ins.dataDir, modsDirOf(ins)))
            case None => ()
        }
    })

    /* 删除 mod 文件 */
    router.delete("/api/v1/instances/{id}/mods/{name}", { ctx, md =>
        if (!Auth.guard(ctx)) {
            return
        }
        match (Instances.findOr404(ctx, md.matchString("id"))) {
            case Some(ins) =>
                let rel = modsDirOf(ins) + "/" + md.matchString("name")
                match (FileManager.safeJoin(ins.dataDir, rel)) {
                    case Some(p) =>
                        try {
                            remove(p, recursive: true)
                            HttpUtil.okMsg(ctx, "已删除")
                        } catch (e: Exception) {
                            HttpUtil.fail(ctx, 4202, "删除失败: ${e.message}")
                        }
                    case None => HttpUtil.fail(ctx, 4103, "非法路径")
                }
            case None => ()
        }
    })

    /* 启用/禁用切换：.jar <-> .jar.disabled */
    router.post("/api/v1/instances/{id}/mods/toggle", { ctx, md =>
        if (!Auth.guard(ctx)) {
            return
        }
        match (Instances.findOr404(ctx, md.matchString("id"))) {
            case Some(ins) =>
                let body = HttpUtil.bodyJson(ctx)
                let name = HttpUtil.str(body, "name", "")
                if (name == "") {
                    HttpUtil.fail(ctx, 4209, "缺少 name")
                    return
                }
                let rel = modsDirOf(ins) + "/" + name
                match (FileManager.safeJoin(ins.dataDir, rel)) {
                    case Some(p) =>
                        if (!exists(p)) {
                            HttpUtil.fail(ctx, 404, "文件不存在")
                            return
                        }
                        try {
                            if (name.endsWith(".disabled")) {
                                rename(p, to: p[..p.size - 9])
                                HttpUtil.okMsg(ctx, "已启用（重启实例生效）")
                            } else {
                                rename(p, to: p + ".disabled")
                                HttpUtil.okMsg(ctx, "已禁用（重启实例生效）")
                            }
                        } catch (e: Exception) {
                            HttpUtil.fail(ctx, 4210, "操作失败: ${e.message}")
                        }
                    case None => HttpUtil.fail(ctx, 4103, "非法路径")
                }
            case None => ()
        }
    })

    /* Steam 创意工坊：列表（DST/PZ） */
    router.get("/api/v1/instances/{id}/workshop", { ctx, md =>
        if (!Auth.guard(ctx)) {
            return
        }
        match (Instances.findOr404(ctx, md.matchString("id"))) {
            case Some(ins) =>
                let (source, link) = Games.modSourceOf(ins.game)
                let entries = JsonArray()
                for ((id, name) in loadWorkshop(ins)) {
                    entries.add(Jsons.obj([("id", JsonString(id)), ("name", JsonString(name))]))
                }
                HttpUtil.ok(ctx, Jsons.obj([
                    ("source", JsonString(source)),
                    ("searchUrl", JsonString(link)),
                    ("entries", entries)
                ]))
            case None => ()
        }
    })

    /* 工坊按 ID 添加：DST 写 setup.lua，PZ 写 ini（body: modId/name/pzModId） */
    router.post("/api/v1/instances/{id}/workshop", { ctx, md =>
        if (!Auth.guard(ctx)) {
            return
        }
        match (Instances.findOr404(ctx, md.matchString("id"))) {
            case Some(ins) =>
                if (ins.game != "dst" && ins.game != "zomboid") {
                    HttpUtil.fail(ctx, 4211, "该游戏不使用 Steam 创意工坊")
                    return
                }
                let body = HttpUtil.bodyJson(ctx)
                let modId = HttpUtil.str(body, "modId", "").trimAscii()
                let name = HttpUtil.str(body, "name", "").trimAscii()
                let pzModId = HttpUtil.str(body, "pzModId", "").trimAscii()
                match (workshopAdd(ins, modId, name, pzModId)) {
                    case None => HttpUtil.okMsg(ctx, "已添加 ${modId}（重启实例后服务器自动下载）")
                    case Some(e) => HttpUtil.fail(ctx, 4212, e)
                }
            case None => ()
        }
    })

    /* 工坊移除 */
    router.delete("/api/v1/instances/{id}/workshop/{modId}", { ctx, md =>
        if (!Auth.guard(ctx)) {
            return
        }
        match (Instances.findOr404(ctx, md.matchString("id"))) {
            case Some(ins) =>
                workshopRemove(ins, md.matchString("modId"))
                HttpUtil.okMsg(ctx, "已移除（重启实例生效）")
            case None => ()
        }
    })

    /* URL 直链安装（泰拉瑞亚插件等）：下载进 mods 目录，zip 自动解压 */
    router.post("/api/v1/instances/{id}/mods/url-install", { ctx, md =>
        if (!Auth.guard(ctx)) {
            return
        }
        match (Instances.findOr404(ctx, md.matchString("id"))) {
            case Some(ins) =>
                let body = HttpUtil.bodyJson(ctx)
                let url = HttpUtil.str(body, "url", "").trimAscii()
                if (!url.startsWith("http://") && !url.startsWith("https://")) {
                    HttpUtil.fail(ctx, 4213, "URL 必须以 http(s):// 开头")
                    return
                }
                let fileName = lastSegOfUrl(url)
                if (fileName == "") {
                    HttpUtil.fail(ctx, 4214, "无法从 URL 提取文件名")
                    return
                }
                let fullDir = ins.dataDir + "/" + modsDirOf(ins)
                if (!exists(fullDir)) {
                    Directory.create(fullDir, recursive: true)
                }
                match (Modrinth.download(url, fullDir + "/" + fileName)) {
                    case Some(err) => HttpUtil.fail(ctx, 4208, err)
                    case None =>
                        // zip 下载后自动解压并清理压缩包
                        if (fileName.toAsciiLower().endsWith(".zip")) {
                            let (_, _, _) = Process.runOutput("unzip", ["-o", "-q", fullDir + "/" + fileName, "-d", fullDir])
                            try {
                                remove(fullDir + "/" + fileName)
                            } catch (_: Exception) {
                                ()
                            }
                            HttpUtil.okMsg(ctx, "已下载并解压到 ${modsDirOf(ins)}/")
                        } else {
                            HttpUtil.okMsg(ctx, "已下载 ${fileName} 到 ${modsDirOf(ins)}/")
                        }
                }
            case None => ()
        }
    })

    /* 整合包搜索 */
    router.get("/api/v1/modrinth/modpacks", { ctx, _ =>
        if (!Auth.guard(ctx)) {
            return
        }
        var q = ctx.request.form.get("q") ?? ""
        if (q == "") {
            q = "*"
        }
        let facets = "[[\"project_type:modpack\"]]"
        let url = "https://api.modrinth.com/v2/search?query=" + Modrinth.urlEnc(q) + "&facets=" + Modrinth.urlEnc(facets) + "&limit=12"
        match (Modrinth.getJson(url)) {
            case Some(v) => HttpUtil.ok(ctx, v)
            case None => HttpUtil.fail(ctx, 4215, "整合包搜索失败（检查网络）")
        }
    })

    /* 从整合包创建实例（自动下载装配） */
    router.post("/api/v1/instances/from-modpack", { ctx, _ =>
        if (!Auth.guard(ctx) || !Auth.allowAdmin(ctx)) {
            return
        }
        let body = HttpUtil.bodyJson(ctx)
        match (createFromModpack(body)) {
            case None => HttpUtil.okMsg(ctx, "整合包实例创建中：镜像启动后将自动下载全部内容，耐心等待日志出现 Done")
            case Some(e) => HttpUtil.fail(ctx, 4216, e)
        }
    })

    /* Modrinth 搜索（带实例参数时按其版本过滤） */
    router.get("/api/v1/modrinth/search", { ctx, _ =>
        if (!Auth.guard(ctx)) {
            return
        }
        let q = ctx.request.form.get("q") ?? ""
        let instId = ctx.request.form.get("instance") ?? ""
        match (Store.data().findInstance(instId)) {
            case Some(ins) =>
                match (Modrinth.search(q, ins)) {
                    case Some(v) => HttpUtil.ok(ctx, v)
                    case None => HttpUtil.fail(ctx, 4203, "Modrinth 请求失败（检查网络）")
                }
            case None =>
                match (Modrinth.search(q, Instance())) {
                    case Some(v) => HttpUtil.ok(ctx, v)
                    case None => HttpUtil.fail(ctx, 4203, "Modrinth 请求失败（检查网络）")
                }
        }
    })

    /* Modrinth 项目版本列表 */
    router.get("/api/v1/modrinth/versions", { ctx, _ =>
        if (!Auth.guard(ctx)) {
            return
        }
        let pid = ctx.request.form.get("project") ?? ""
        if (pid == "") {
            HttpUtil.fail(ctx, 4204, "缺少 project 参数")
            return
        }
        match (Modrinth.versions(pid)) {
            case Some(v) => HttpUtil.ok(ctx, v)
            case None => HttpUtil.fail(ctx, 4205, "获取版本失败")
        }
    })

    /* 一键安装：下载指定版本主文件进 mods 目录 */
    router.post("/api/v1/instances/{id}/mods/install", { ctx, md =>
        if (!Auth.guard(ctx)) {
            return
        }
        match (Instances.findOr404(ctx, md.matchString("id"))) {
            case Some(ins) =>
                let body = HttpUtil.bodyJson(ctx)
                let projectId = HttpUtil.str(body, "projectId", "")
                let versionId = HttpUtil.str(body, "versionId", "")
                if (projectId == "" || versionId == "") {
                    HttpUtil.fail(ctx, 4206, "需要 projectId 与 versionId")
                    return
                }
                let fullDir = ins.dataDir + "/" + modsDirOf(ins)
                if (!exists(fullDir)) {
                    Directory.create(fullDir, recursive: true)
                }
                let vList = match (Modrinth.versions(projectId)) {
                    case Some(v) => v
                    case None => HttpUtil.fail(ctx, 4205, "获取版本失败"); return
                }
                var fileUrl = ""
                var fileName = ""
                match (pickVersion(vList, versionId)) {
                    case Some(pair) =>
                        fileUrl = pair[0]
                        fileName = pair[1]
                    case None =>
                        HttpUtil.fail(ctx, 4207, "未找到指定版本")
                        return
                }
                match (Modrinth.download(fileUrl, fullDir + "/" + fileName)) {
                    case None => HttpUtil.okMsg(ctx, "已安装 ${fileName}（重启实例后生效）")
                    case Some(err) => HttpUtil.fail(ctx, 4208, err)
                }
            case None => ()
        }
    })
}

/* ---------------- Steam 创意工坊（DST / PZ）---------------- */

/* 台账：数据目录/gamepanel-workshop.json，同时尽力写入游戏自己的配置 */
func workshopFile(ins: Instance): String {
    return ins.dataDir + "/gamepanel-workshop.json"
}

func loadWorkshop(ins: Instance): ArrayList<(String, String)> {
    let list = ArrayList<(String, String)>()   // (modId, 名称)
    if (!exists(workshopFile(ins))) {
        return list
    }
    try {
        let v = JsonValue.fromStr(String.fromUtf8(File.readFrom(workshopFile(ins))))
        if (HttpUtil.kindIs(v, JsonKind.JsArray)) {
            for (item in v.asArray().getItems()) {
                if (HttpUtil.kindIs(item, JsonKind.JsObject)) {
                    let o = item.asObject()
                    list.add((Jsons.text(o.get("id") ?? JsonString("")),
                        Jsons.text(o.get("name") ?? JsonString(""))))
                }
            }
        }
    } catch (_: Exception) {
        ()
    }
    return list
}

func saveWorkshop(ins: Instance, list: ArrayList<(String, String)>): Unit {
    let arr = JsonArray()
    for ((id, name) in list) {
        arr.add(Jsons.obj([("id", JsonString(id)), ("name", JsonString(name))]))
    }
    File.writeTo(workshopFile(ins), arr.toJsonString().toArray())
}

/* 添加：台账 + 游戏侧写入。
   DST -> 追加 ServerModSetup("id") 到 mods/dedicated_server_mods_setup.lua（目录存在时）
   PZ  -> servertest.ini 的 WorkshopItems 追加 ID；ModID（可选）追加到 Mods= */
func workshopAdd(ins: Instance, modId: String, name: String, pzModId: String): ?String {
    if (modId == "") {
        return Some("modId 不能为空")
    }
    let list = loadWorkshop(ins)
    for ((id, _) in list) {
        if (id == modId) {
            return Some("该 Workshop ID 已添加")
        }
    }
    if (ins.game == "dst") {
        let setupLua = ins.dataDir + "/mods/dedicated_server_mods_setup.lua"
        if (exists(ins.dataDir + "/mods")) {
            var text = ""
            if (exists(setupLua)) {
                text = String.fromUtf8(File.readFrom(setupLua))
                if (!text.endsWith("\n") && text != "") {
                    text = text + "\n"
                }
            }
            text = text + "ServerSetupMarker_do_not_remove_${modId}\nServerModSetup(\"${modId}\") -- ${name}\n"
            File.writeTo(setupLua, text.toArray())
        }
    }
    if (ins.game == "zomboid") {
        appendIniList(ins, "WorkshopItems", modId)
        if (pzModId != "") {
            appendIniList(ins, "Mods", pzModId)
        }
    }
    list.add((modId, name))
    saveWorkshop(ins, list)
    return None
}

func workshopRemove(ins: Instance, modId: String): Unit {
    let list = loadWorkshop(ins)
    let keep = ArrayList<(String, String)>()
    for ((id, name) in list) {
        if (id != modId) {
            keep.add((id, name))
        }
    }
    saveWorkshop(ins, keep)
    if (ins.game == "dst") {
        let setupLua = ins.dataDir + "/mods/dedicated_server_mods_setup.lua"
        if (exists(setupLua)) {
            let out = ArrayList<String>()
            for (line in String.fromUtf8(File.readFrom(setupLua)).split("\n")) {
                if (line.contains(modId)) {
                    continue
                }
                out.add(line)
            }
            File.writeTo(setupLua, joinStr(out, "\n").toArray())
        }
    }
    if (ins.game == "zomboid") {
        // 从 ini 列表移除：读值 -> 过滤 -> 写回
        removeFromIniList(ins, "WorkshopItems", modId)
    }
}

/* ini 键值列表追加（逗号分隔） */
func appendIniList(ins: Instance, key: String, value: String): Unit {
    let f = ConfigField("Server/servertest.ini", "ini", "servertest.${key}", "", "text", [], "", "")
    let (cur, fileOk) = GameConfig.readField(ins.dataDir, f)
    var next = value
    if (fileOk && cur != "") {
        if (cur.contains(value)) {
            return
        }
        next = cur + "," + value
    }
    GameConfig.writeField(ins, f, next)
}

func removeFromIniList(ins: Instance, key: String, value: String): Unit {
    let f = ConfigField("Server/servertest.ini", "ini", "servertest.${key}", "", "text", [], "", "")
    let (cur, _) = GameConfig.readField(ins.dataDir, f)
    if (cur == "") {
        return
    }
    let parts = ArrayList<String>()
    for (p in cur.split(",")) {
        if (p.trimAscii() != value && p.trimAscii() != "") {
            parts.add(p.trimAscii())
        }
    }
    GameConfig.writeField(ins, f, joinStr(parts, ","))
}

func joinStr(items: ArrayList<String>, sep: String): String {
    let sb = StringBuilder()
    for (i in 0..items.size) {
        if (i > 0) {
            sb.append(sep)
        }
        sb.append(items[i])
    }
    return sb.toString()
}

/* ---------------- Modrinth 整合包一键开服 ---------------- */

/* 自主装配：下载 .mrpack -> 解析 modrinth.index.json ->
   按 dependencies 设置加载器 env -> 下载全部服务端兼容文件到数据目录 -> 启动。
   不依赖镜像的整合包特性，任何 itzg 版本都可用。 */
func createFromModpack(body: JsonObject): ?String {
    let projectId = HttpUtil.str(body, "projectId", "").trimAscii()
    let versionId = HttpUtil.str(body, "versionId", "").trimAscii()
    let name = HttpUtil.str(body, "name", "").trimAscii()
    if (projectId == "" || versionId == "") {
        return Some("需要 projectId 与 versionId")
    }
    if (name == "") {
        return Some("实例名称不能为空")
    }
    var portStr = HttpUtil.str(body, "port", "").trimAscii()
    if (portStr == "") {
        portStr = "25565"
    }
    for (c in portStr.toRuneArray()) {
        if (!(c >= r'0' && c <= r'9')) {
            return Some("端口只能是数字")
        }
    }
    for (other in Store.data().instances) {
        for (p in other.ports) {
            if (p[..idxOf(p, ":")] == portStr) {
                return Some("端口 ${portStr} 已被实例「${other.name}」占用")
            }
        }
    }
    let ins = Instance()
    ins.id = Instances.genId()
    ins.name = name
    ins.game = "minecraft"
    ins.version = "modpack-" + versionId[..8]
    ins.image = "itzg/minecraft-server:latest"
    ins.dataDir = Paths.instanceDir(ins.id)
    ins.mountPath = "/data"
    ins.ports.add("${portStr}:25565")
    ins.env.add("EULA", "TRUE")
    ins.env.add("RCON_ENABLED", "TRUE")
    ins.env.add("RCON_PASSWORD", "gamepanel")
    ins.memoryMB = HttpUtil.int(body, "memoryMB", 4096)
    match (body.get("cpus")) {
        case Some(v) =>
            if (HttpUtil.kindIs(v, JsonKind.JsFloat)) {
                ins.cpus = v.asFloat().getValue()
            } else if (HttpUtil.kindIs(v, JsonKind.JsInt)) {
                ins.cpus = Float64.parse(v.asInt().getValue().toString())
            }
        case None => ()
    }
    ins.autoStart = true
    ins.createdAt = Instances.nowStr()
    if (!exists(ins.dataDir)) {
        Directory.create(ins.dataDir, recursive: true)
    }
    Store.update({ d => d.instances.add(ins) })
    // 后台装配（下载整合包全部内容后再启动）
    let pid = projectId
    let vid = versionId
    spawn {
        assembleModpack(ins.id, pid, vid)
    }
    return None
}

func assembleModpack(id: String, projectId: String, versionId: String): Unit {
    Ops.set(id, "assembling")
    var failed: ?String = None
    let tmpDir = "/tmp/gp-mp-" + id
    try {
        // 1. 拿版本主文件（.mrpack）
        let vList = match (Modrinth.versions(projectId)) {
            case Some(v) => v
            case None => throw Exception("获取整合包版本失败")
        }
        var url = ""
        match (pickVersion(vList, versionId)) {
            case Some(pair) => url = pair[0]
            case None => throw Exception("未找到整合包文件")
        }
        let mrpack = tmpDir + "/pack.mrpack"
        if (!exists(tmpDir)) {
            Directory.create(tmpDir, recursive: true)
        }
        match (Modrinth.download(url, mrpack)) {
            case Some(e) => throw Exception(e)
            case None => ()
        }
        // 2. 解压出索引
        let (_, _, unzipErr) = Process.runOutput("unzip", ["-o", "-q", mrpack, "-d", tmpDir])
        let indexPath = tmpDir + "/modrinth.index.json"
        if (!exists(indexPath)) {
            var e = String.fromUtf8(unzipErr).trimAscii()
            if (e == "") {
                e = "mrpack 内无 modrinth.index.json"
            }
            throw Exception("解压失败: ${e}")
        }
        let idx = JsonValue.fromStr(String.fromUtf8(File.readFrom(indexPath))).asObject()
        // 3. dependencies -> itzg 加载器 env
        applyLoaderEnv(id, idx)
        // 4. 下载全部服务端兼容文件（8 并发分批）
        var total: Int64 = 0
        var skipped: Int64 = 0
        match (Store.data().findInstance(id)) {
            case Some(ins) =>
                match (idx.get("files")) {
                    case Some(fs) =>
                        if (HttpUtil.kindIs(fs, JsonKind.JsArray)) {
                            for (f in fs.asArray().getItems()) {
                                if (!HttpUtil.kindIs(f, JsonKind.JsObject)) {
                                    continue
                                }
                                let fo = f.asObject()
                                // 服务端 unsupported 的文件跳过（纯客户端 Mod）
                                var serverSide = "required"
                                match (fo.get("env")) {
                                    case Some(ev) =>
                                        if (HttpUtil.kindIs(ev, JsonKind.JsObject)) {
                                            match (ev.asObject().get("server")) {
                                                case Some(sv) => serverSide = Jsons.text(sv)
                                                case None => ()
                                            }
                                        }
                                    case None => ()
                                }
                                if (serverSide == "unsupported") {
                                    skipped += 1
                                    continue
                                }
                                var fileUrl = ""
                                match (fo.get("downloads")) {
                                    case Some(dl) =>
                                        if (HttpUtil.kindIs(dl, JsonKind.JsArray)) {
                                            let items = dl.asArray().getItems()
                                            if (items.size > 0) {
                                                fileUrl = Jsons.text(items[0])
                                            }
                                        }
                                    case None => ()
                                }
                                let path = Jsons.text(fo.get("path") ?? JsonString(""))
                                if (fileUrl == "" || path == "") {
                                    continue
                                }
                                // 逐个下载（父目录自动创建）
                                let dest = ins.dataDir + "/" + path
                                let slash = lastIdxOf(dest, "/")
                                if (slash > 0) {
                                    let dir = dest[..slash]
                                    if (!exists(dir)) {
                                        Directory.create(dir, recursive: true)
                                    }
                                }
                                match (Modrinth.download(fileUrl, dest)) {
                                    case Some(e) => println("[modpack] ${path} 下载失败: ${e}")
                                    case None => total += 1
                                }
                            }
                        }
                    case None => ()
                }
            case None => throw Exception("实例丢失")
        }
        println("[modpack] ${id} 装配完成：${total} 个文件（跳过 ${skipped} 个纯客户端文件）")
        // 5. 启动
        match (Store.data().findInstance(id)) {
            case Some(ins) =>
                let pull = Docker.pull(ins.image)
                if (!pull.ok()) {
                    println("[modpack] 拉取镜像失败: ${pull.stderr}")
                }
                let r = Docker.runInstance(ins)
                if (r.ok()) {
                    ConsolePipe.attach(ins)
                } else {
                    println("[modpack] 启动失败: ${r.stderr}")
                }
            case None => ()
        }
    } catch (e: Exception) {
        failed = Some(e.message)
        println("[modpack] ${id} 装配失败: ${e.message}")
    }
    Ops.clear(id)
    match (failed) {
        case Some(msg) =>
            Store.update({ d =>
                match (d.findInstance(id)) {
                    case Some(cur) => cur.autoStart = false
                    case None => ()
                }
            })
            println("[modpack] ${id} 已保留实例（数据目录可能不完整），可删除后重试：${msg}")
        case None => ()
    }
    try {
        remove(tmpDir, recursive: true)
    } catch (_: Exception) {
        ()
    }
}

/* 按 index 的 dependencies 写入 itzg 加载器环境变量 */
func applyLoaderEnv(id: String, idx: JsonObject): Unit {
    Store.update({ d =>
        match (d.findInstance(id)) {
            case Some(ins) =>
                match (idx.get("dependencies")) {
                    case Some(dep) =>
                        if (HttpUtil.kindIs(dep, JsonKind.JsObject)) {
                            let o = dep.asObject()
                            let put = { k, v => ins.env.add(k, v) }
                            match (o.get("minecraft")) {
                                case Some(mv) => put("VERSION", Jsons.text(mv))
                                case None => ()
                            }
                            match (o.get("fabric-loader")) {
                                case Some(lv) =>
                                    put("TYPE", "FABRIC")
                                    put("FABRIC_LOADER_VERSION", Jsons.text(lv))
                                case None => ()
                            }
                            match (o.get("forge")) {
                                case Some(lv) =>
                                    put("TYPE", "FORGE")
                                    put("FORGE_VERSION", Jsons.text(lv))
                                case None => ()
                            }
                            match (o.get("neoforge")) {
                                case Some(lv) =>
                                    put("TYPE", "NEOFORGE")
                                    put("NEOFORGE_VERSION", Jsons.text(lv))
                                case None => ()
                            }
                            match (o.get("quilt-loader")) {
                                case Some(lv) =>
                                    put("TYPE", "QUILT")
                                    put("QUILT_LOADER_VERSION", Jsons.text(lv))
                                case None => ()
                            }
                        }
                    case None => ()
                }
            case None => ()
        }
    })
}

func modsDirOf(ins: Instance): String {
    match (Games.find(ins.game)) {
        case Some(t) => return t.modsDir
        case None => return "mods"
    }
}

/* 从版本数组中挑出目标版本的主文件 (url, filename) */
func pickVersion(vList: JsonValue, versionId: String): ?(String, String) {
    if (!HttpUtil.kindIs(vList, JsonKind.JsArray)) {
        return None
    }
    for (item in vList.asArray().getItems()) {
        if (!HttpUtil.kindIs(item, JsonKind.JsObject)) {
            continue
        }
        let o = item.asObject()
        if (Jsons.text(o.get("id") ?? JsonString("")) == versionId) {
            match (o.get("files")) {
                case Some(fs) =>
                    if (HttpUtil.kindIs(fs, JsonKind.JsArray)) {
                        for (f in fs.asArray().getItems()) {
                            if (!HttpUtil.kindIs(f, JsonKind.JsObject)) {
                                continue
                            }
                            let fo = f.asObject()
                            let primary = match (fo.get("primary")) {
                                case Some(p) => Jsons.text(p) == "true"
                                case None => false
                            }
                            if (primary) {
                                let url = Jsons.text(fo.get("url") ?? JsonString(""))
                                let fn = Jsons.text(fo.get("filename") ?? JsonString(""))
                                if (url != "" && fn != "") {
                                    return Some((url, fn))
                                }
                            }
                        }
                    }
                case None => ()
            }
        }
    }
    return None
}


func lastSegOfUrl(url: String): String {
    // 去掉 query/fragment 再取最后一段
    var path = url
    let q = idxOf(path, "?")
    if (q > 0) {
        path = path[..q]
    }
    let h = idxOf(path, "#")
    if (h > 0) {
        path = path[..h]
    }
    let slash = lastIdxOf(path, "/")
    if (slash >= 0) {
        return path[slash + 1..]
    }
    return ""
}

/* ---------------- Minecraft 版本动态列表 ---------------- */

/* 从各官方 API 拉取可用版本（用于创建向导，替代硬编码静态表）：
   paper   -> fill.papermc.io v3（按大版本分组，取每组正式版）
   vanilla -> Mojang piston-meta（release 类型）
   fabric  -> meta.fabricmc.net（stable）
   失败返回 None，前端回退静态表 */
public func fetchMcVersions(loader: String): ?Array<String> {
    match (loader) {
        case "paper" =>
            match (Modrinth.curlGetJson("https://fill.papermc.io/v3/projects/paper")) {
                case Some(v) =>
                    if (!HttpUtil.kindIs(v, JsonKind.JsObject)) {
                        return None
                    }
                    match (v.asObject().get("versions")) {
                        case Some(vs) =>
                            if (!HttpUtil.kindIs(vs, JsonKind.JsObject)) {
                                return None
                            }
                            // keys 即大版本号（26.3/26.2/1.21…），值数组首项为正式版
                            let out = ArrayList<String>()
                            for ((major, _) in vs.asObject().getFields()) {
                                out.add(major)
                            }
                            return Some(out.toArray())
                        case None => return None
                    }
                case None => return None
            }
        case "vanilla" =>
            match (Modrinth.curlGetJson("https://piston-meta.mojang.com/mc/game/version_manifest_v2.json")) {
                case Some(v) =>
                    let out = ArrayList<String>()
                    match (v.asObject().get("versions")) {
                        case Some(vs) =>
                            if (HttpUtil.kindIs(vs, JsonKind.JsArray)) {
                                for (item in vs.asArray().getItems()) {
                                    if (!HttpUtil.kindIs(item, JsonKind.JsObject)) {
                                        continue
                                    }
                                    let o = item.asObject()
                                    if (Jsons.text(o.get("type") ?? JsonString("")) != "release") {
                                        continue
                                    }
                                    out.add(Jsons.text(o.get("id") ?? JsonString("")))
                                    if (out.size >= 15) {
                                        break
                                    }
                                }
                            }
                        case None => ()
                    }
                    if (out.size == 0) {
                        return None
                    }
                    return Some(out.toArray())
                case None => return None
            }
        case "fabric" =>
            match (Modrinth.curlGetJson("https://meta.fabricmc.net/v2/versions/game")) {
                case Some(v) =>
                    if (!HttpUtil.kindIs(v, JsonKind.JsArray)) {
                        return None
                    }
                    let out = ArrayList<String>()
                    for (item in v.asArray().getItems()) {
                        if (!HttpUtil.kindIs(item, JsonKind.JsObject)) {
                            continue
                        }
                        let o = item.asObject()
                        if (Jsons.text(o.get("stable") ?? JsonString("false")) != "true") {
                            continue
                        }
                        out.add(Jsons.text(o.get("version") ?? JsonString("")))
                        if (out.size >= 15) {
                            break
                        }
                    }
                    if (out.size == 0) {
                        return None
                    }
                    return Some(out.toArray())
                case None => return None
            }
        case _ => return None
    }
}

public func registerMcVerRoutes(): Unit {
    router.get("/api/v1/mc-versions", { ctx, _ =>
        if (!Auth.guard(ctx)) {
            return
        }
        let loader = ctx.request.form.get("loader") ?? "vanilla"
        match (fetchMcVersions(loader)) {
            case Some(list) => HttpUtil.ok(ctx, Jsons.arr(strArrToJson(list)))
            case None => HttpUtil.fail(ctx, 7301, "获取版本列表失败（回退到内置版本）")
        }
    })
}

func strArrToJson(items: Array<String>): Array<JsonValue> {
    let out = Array<JsonValue>(items.size, repeat: JsonNull())
    for (i in 0..items.size) {
        out[i] = JsonString(items[i])
    }
    return out
}
