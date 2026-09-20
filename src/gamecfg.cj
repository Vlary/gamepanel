package gamepanel

/*
 * 游戏专属配置：按模板 schema 读写实例数据目录里的配置文件。
 * 支持三种格式：
 *   properties — key=value（Minecraft server.properties）
 *   ini        — [段] 下 key=value（DST cluster.ini / PZ servertest.ini），path 为 "段.键"
 *   json       — 点路径（TShock config.json），解析-修改-写回
 * properties/ini 采用行级替换：只改目标行，注释与顺序原样保留；
 * json 无注释语义，整体重新序列化（带缩进）。
 */

import stdx.net.http.*
import stdx.encoding.json.*
import std.fs.*
import std.collection.*
import std.convert.*

public class GameConfig {
    /* 读取一个配置项；文件/键不存在返回 schema 默认值，missing 标记文件是否未生成 */
    public static func readField(dataDir: String, f: ConfigField): (String, Bool) {
        let abs = dataDir + "/" + f.file
        if (!exists(abs)) {
            return (f.def, false)
        }
        let text = String.fromUtf8(File.readFrom(abs))
        let v = match (f.format) {
            case "json" => readJson(text, f.path)
            case "ini" => readIni(text, f.path)
            case _ => readProperties(text, f.path)
        }
        match (v) {
            case Some(s) => return (s, true)
            case None => return (f.def, true)
        }
    }

    static func readProperties(text: String, key: String): ?String {
        for (line in text.split("\n")) {
            let t = line.trimAscii()
            if (t.startsWith("#")) {
                continue
            }
            let eq = idxOf(t, "=")
            if (eq > 0 && t[..eq].trimAscii() == key) {
                return Some(t[eq + 1..].trimAscii())
            }
        }
        return None
    }

    static func readIni(text: String, path: String): ?String {
        let parts = path.split(".")
        if (parts.size != 2) {
            return None
        }
        let section = parts[0]
        let key = parts[1]
        var inSection = false
        for (line in text.split("\n")) {
            let t = line.trimAscii()
            if (t.startsWith("[") && t.endsWith("]")) {
                inSection = t[1..t.size - 1] == section
                continue
            }
            if (!inSection || t.startsWith("#") || t.startsWith(";")) {
                continue
            }
            let eq = idxOf(t, "=")
            if (eq > 0 && t[..eq].trimAscii() == key) {
                return Some(t[eq + 1..].trimAscii())
            }
        }
        return None
    }

    static func readJson(text: String, path: String): ?String {
        try {
            var v: JsonValue = JsonValue.fromStr(text)
            for (seg in path.split(".")) {
                if (!HttpUtil.kindIs(v, JsonKind.JsObject)) {
                    return None
                }
                match (v.asObject().get(seg)) {
                    case Some(next) => v = next
                    case None => return None
                }
            }
            return Some(Jsons.text(v))
        } catch (_: Exception) {
            return None
        }
    }

    /* 写入一个配置项（整个文件重写，逐行替换）。
       容器内进程通常以 root 写配置，宿主用户可能无权直写 bind mount，
       直写失败时回退 docker cp（由 daemon 以 root 执行，总是可行）。 */
    public static func writeField(ins: Instance, f: ConfigField, value: String): ?String {
        let abs = ins.dataDir + "/" + f.file
        var text = ""
        if (exists(abs)) {
            try {
                text = String.fromUtf8(File.readFrom(abs))
            } catch (e: Exception) {
                return Some("读取失败: ${e.message}")
            }
        }
        match (f.format) {
            case "json" =>
                let newText = writeJson(text, f.path, value)
                match (newText) {
                    case Some(n) => text = n
                    case None => return Some("JSON 配置解析失败: ${f.file}")
                }
            case "ini" =>
                text = writeIni(text, f.path, value)
            case _ =>
                text = writeProperties(text, f.path, value)
        }
        try {
            File.writeTo(abs, text.toArray())
            return None
        } catch (_: Exception) {
            // 权限不足：走 docker cp 由 daemon 写入
            let container = ins.containerName()
            if (!Docker.exists(container)) {
                return Some("无写入权限且容器不存在（可先启动实例再保存）")
            }
            let tmp = "/tmp/gp-cfg-" + ins.id + "-" + lastSeg(f.file)
            try {
                File.writeTo(tmp, text.toArray())
                let target = ins.mountPath + "/" + f.file
                let r = Docker.run(["cp", tmp, "${container}:${target}"])
                try {
                    remove(tmp)
                } catch (_: Exception) {
                    ()
                }
                if (r.ok()) {
                    return None
                }
                return Some("docker cp 失败: ${r.stderr.trimAscii()}")
            } catch (e: Exception) {
                return Some("写入失败: ${e.message}")
            }
        }
    }

    /* 测试辅助：暴露内部实现 */
    public static func writePropertiesForTest(text: String, key: String, value: String): String {
        return writeProperties(text, key, value)
    }

    /* properties：逐行找 key= 替换；找不到则追加 */
    static func writeProperties(text: String, key: String, value: String): String {
        let lines = text.split("\n")
        let out = ArrayList<String>()
        var replaced = false
        for (i in 0..lines.size) {
            let line = lines[i]
            let t = line.trimAscii()
            let eq = idxOf(t, "=")
            if (!replaced && eq > 0 && !t.startsWith("#") && t[..eq].trimAscii() == key) {
                out.add("${key}=${value}")
                replaced = true
            } else if (line != "" || i < lines.size - 1) {
                out.add(line)
            }
        }
        if (!replaced) {
            if (out.size > 0 && out[out.size - 1] != "") {
                out.add("")
            }
            out.add("${key}=${value}")
        }
        return joinLines(out)
    }

    /* ini：在目标段内替换/插入；无目标段则文末新建 */
    static func writeIni(text: String, path: String, value: String): String {
        let parts = path.split(".")
        if (parts.size != 2) {
            return text
        }
        let section = parts[0]
        let key = parts[1]
        let lines = text.split("\n")
        let out = ArrayList<String>()
        var inSection = false
        var sectionSeen = false
        var replaced = false
        var lastContentLine = -1
        for (i in 0..lines.size) {
            let line = lines[i]
            let t = line.trimAscii()
            if (t.startsWith("[") && t.endsWith("]")) {
                // 离开目标段且键未替换：在段末补插
                if (inSection && !replaced) {
                    out.add("${key}=${value}")
                    replaced = true
                }
                inSection = t[1..t.size - 1] == section
                if (inSection) {
                    sectionSeen = true
                }
            } else if (inSection && !replaced) {
                let eq = idxOf(t, "=")
                if (eq > 0 && !t.startsWith("#") && !t.startsWith(";") && t[..eq].trimAscii() == key) {
                    out.add("${key}=${value}")
                    replaced = true
                    if (line != "") {
                        lastContentLine = out.size - 1
                    }
                    continue
                }
            }
            if (line != "" || i < lines.size - 1) {
                out.add(line)
                if (line != "") {
                    lastContentLine = out.size - 1
                }
            }
        }
        if (inSection && !replaced) {
            // 键在文件最后一个段内
            out.add("${key}=${value}")
            replaced = true
        }
        if (!sectionSeen) {
            out.add("")
            out.add("[${section}]")
            out.add("${key}=${value}")
        }
        return joinLines(out)
    }

    /* json：解析 -> 沿路径定位父对象 -> 按原值类型写入 -> 缩进序列化 */
    static func writeJson(text: String, path: String, value: String): ?String {
        var root: JsonValue
        try {
            root = JsonValue.fromStr(text)
        } catch (_: Exception) {
            return None
        }
        if (!HttpUtil.kindIs(root, JsonKind.JsObject)) {
            return None
        }
        let segs = path.split(".")
        var cur = root.asObject()
        for (i in 0..segs.size - 1) {
            match (cur.get(segs[i])) {
                case Some(next) =>
                    if (!HttpUtil.kindIs(next, JsonKind.JsObject)) {
                        return None
                    }
                    cur = next.asObject()
                case None =>
                    let created = JsonObject()
                    cur.put(segs[i], created)
                    cur = created
            }
        }
        let leaf = segs[segs.size - 1]
        // 按现有值类型转换，保持 number/bool/string 语义
        var newVal: JsonValue = JsonString(value)
        match (cur.get(leaf)) {
            case Some(old) =>
                if (HttpUtil.kindIs(old, JsonKind.JsInt)) {
                    try {
                        newVal = JsonInt(Int64.parse(value))
                    } catch (_: Exception) {
                        newVal = old
                    }
                } else if (HttpUtil.kindIs(old, JsonKind.JsFloat)) {
                    try {
                        newVal = JsonFloat(Float64.parse(value))
                    } catch (_: Exception) {
                        newVal = old
                    }
                } else if (HttpUtil.kindIs(old, JsonKind.JsBool)) {
                    newVal = JsonBool(value == "true")
                }
            case None => ()
        }
        cur.put(leaf, newVal)
        return Some(root.toJsonString())
    }

    static func joinLines(lines: ArrayList<String>): String {
        let sb = StringBuilder()
        for (i in 0..lines.size) {
            sb.append(lines[i])
            if (i < lines.size - 1) {
                sb.append("\n")
            }
        }
        return sb.toString()
    }
}

/* ---------------- REST 路由 ---------------- */

public func registerGameCfgRoutes(): Unit {
    /* 读取实例的游戏专属配置（模板 schema + 当前值） */
    router.get("/api/v1/instances/{id}/game-config", { ctx, md =>
        if (!Auth.guard(ctx)) {
            return
        }
        match (Instances.findOr404(ctx, md.matchString("id"))) {
            case Some(ins) =>
                match (Games.find(ins.game)) {
                    case Some(tpl) =>
                        let arr = JsonArray()
                        var fileMissing = false
                        for (f in tpl.configFields) {
                            let (v, existsNow) = GameConfig.readField(ins.dataDir, f)
                            if (!existsNow) {
                                fileMissing = true
                            }
                            let opts = JsonArray()
                            for ((ov, ol) in f.options) {
                                opts.add(Jsons.obj([("value", JsonString(ov)), ("label", JsonString(ol))]))
                            }
                            arr.add(Jsons.obj([
                                ("label", JsonString(f.label)),
                                ("kind", JsonString(f.kind)),
                                ("path", JsonString(f.path)),
                                ("value", JsonString(v)),
                                ("default", JsonString(f.def)),
                                ("options", opts),
                                ("help", JsonString(f.help)),
                                ("group", JsonString(f.group))
                            ]))
                        }
                        HttpUtil.ok(ctx, Jsons.obj([("fields", arr), ("fileMissing", JsonBool(fileMissing))]))
                    case None =>
                        HttpUtil.fail(ctx, 4300, "该游戏未定义专属配置")
                }
            case None => ()
        }
    })

    /* 批量保存：body {"values": {"路径": "值"}} */
    router.put("/api/v1/instances/{id}/game-config", { ctx, md =>
        if (!Auth.guard(ctx)) {
            return
        }
        match (Instances.findOr404(ctx, md.matchString("id"))) {
            case Some(ins) =>
                match (Games.find(ins.game)) {
                    case Some(tpl) =>
                        let body = HttpUtil.bodyJson(ctx)
                        let values = match (body.get("values")) {
                            case Some(v) =>
                                if (HttpUtil.kindIs(v, JsonKind.JsObject)) {
                                    v.asObject()
                                } else {
                                    HttpUtil.fail(ctx, 4301, "values 必须是对象")
                                    return
                                }
                            case None =>
                                HttpUtil.fail(ctx, 4301, "缺少 values 字段")
                                return
                        }
                        var done: Int64 = 0
                        var firstErr: ?String = None
                        for (f in tpl.configFields) {
                            match (values.get(f.path)) {
                                case Some(v) =>
                                    let err = GameConfig.writeField(ins, f, Jsons.text(v).trimAscii())
                                    match (err) {
                                        case Some(e) =>
                                            if (firstErr == None) {
                                                firstErr = Some("${f.label}: ${e}")
                                            }
                                        case None => done += 1
                                    }
                                case None => ()
                            }
                        }
                        match (firstErr) {
                            case Some(e) => HttpUtil.fail(ctx, 4302, "部分保存失败：${e}")
                            case None => HttpUtil.okMsg(ctx, "已保存 ${done} 项，重启实例后生效")
                        }
                    case None => HttpUtil.fail(ctx, 4300, "该游戏未定义专属配置")
                }
            case None => ()
        }
    })
}
