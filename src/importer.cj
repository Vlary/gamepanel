package gamepanel

/*
 * 导入已有 Docker 容器：把用户手工 docker run 起来的游戏服纳管进面板。
 * 原则：绝不重建/重启容器，只读取 docker inspect 生成实例元数据；
 *   - 容器名直接作为实例 ID（后续生命周期操作沿用原容器）
 *   - 数据目录取第一个 bind mount 的宿主源路径
 *   - 镜像与端口映射原样保留；容器内环境变量写入 extraEnv（用户可精简）
 *   - 按镜像名猜游戏类型，命中模板则套用该游戏的快照路径/Mod 目录等定义
 */

import stdx.net.http.*
import stdx.encoding.json.*
import std.collection.*

public class Importer {
    /* 镜像名 -> 游戏模板 key */
    public static func guessGame(image: String): String {
        let img = image.toAsciiLower()
        if (img.contains("minecraft")) {
            return "minecraft"
        }
        if (img.contains("dst")) {
            return "dst"
        }
        if (img.contains("terraria")) {
            return "terraria"
        }
        if (img.contains("zomboid")) {
            return "zomboid"
        }
        return "custom"
    }

    /* 执行导入，返回错误说明或 None */
    public static func doImport(container: String, name: String): ?String {
        let cname = container.trimAscii()
        if (cname == "") {
            return Some("容器名不能为空")
        }
        if (!Docker.exists(cname)) {
            return Some("容器不存在: ${cname}")
        }
        // 容器名已被面板纳管则拒绝
        match (Store.data().findInstance(cname)) {
            case Some(_) => return Some("该容器已在面板管理中")
            case None => ()
        }
        let r = Docker.run(["inspect", cname])
        if (!r.ok()) {
            return Some("inspect 失败: ${r.stderr.trimAscii()}")
        }
        let root = match (parseFirst(r.stdout)) {
            case Some(v) => v
            case None => return Some("inspect 输出解析失败")
        }
        let cfg = getObj(root, "Config") ?? JsonObject()
        // 镜像
        let image = Jsons.text(cfg.get("Image") ?? JsonString("")) 
        if (image == "") {
            return Some("无法读取容器镜像")
        }
        let game = guessGame(image)
        let ins = Instance()
        ins.id = cname
        if (name == "") {
            ins.name = cname
        } else {
            ins.name = name
        }
        ins.game = game
        ins.version = "imported"
        ins.image = image
        ins.createdAt = Instances.nowStr()
        ins.autoStart = false
        // 挂载：取第一个 bind
        match (getObj(root, "HostConfig")) {
            case Some(hc) =>
                match (hc.get("RestartPolicy")) {
                    case Some(rp) =>
                        if (HttpUtil.kindIs(rp, JsonKind.JsObject)) {
                            let policy = Jsons.text(rp.asObject().get("Name") ?? JsonString(""))
                            if (policy == "unless-stopped" || policy == "always") {
                                ins.autoStart = true
                            }
                        }
                    case None => ()
                }
            case None => ()
        }
        match (root.get("Mounts")) {
            case Some(ms) =>
                if (HttpUtil.kindIs(ms, JsonKind.JsArray)) {
                    for (m in ms.asArray().getItems()) {
                        if (!HttpUtil.kindIs(m, JsonKind.JsObject)) {
                            continue
                        }
                        let mo = m.asObject()
                        let typ = Jsons.text(mo.get("Type") ?? JsonString(""))
                        if (typ == "bind") {
                            ins.dataDir = Jsons.text(mo.get("Source") ?? JsonString(""))
                            ins.mountPath = Jsons.text(mo.get("Destination") ?? JsonString(""))
                            break
                        }
                    }
                }
            case None => ()
        }
        // 端口：HostConfig.PortBindings（HostConfig 与 Config 同级）
        match (getObj(root, "HostConfig")) {
            case Some(hc) =>
                match (hc.get("PortBindings")) {
                    case Some(pb) =>
                        if (HttpUtil.kindIs(pb, JsonKind.JsObject)) {
                            for ((containerPort, binds) in pb.asObject().getFields()) {
                                if (!HttpUtil.kindIs(binds, JsonKind.JsArray)) {
                                    continue
                                }
                                for (b in binds.asArray().getItems()) {
                                    if (HttpUtil.kindIs(b, JsonKind.JsObject)) {
                                        let hostPort = Jsons.text(b.asObject().get("HostPort") ?? JsonString(""))
                                        if (hostPort != "") {
                                            ins.ports.add("${hostPort}:${containerPort}")
                                        }
                                    }
                                }
                            }
                        }
                    case None => ()
                }
            case None => ()
        }
        // 环境变量 -> extraEnv（过滤 PATH/LANG 等系统变量）
        match (cfg.get("Env")) {
            case Some(envs) =>
                if (HttpUtil.kindIs(envs, JsonKind.JsArray)) {
                    for (e in envs.asArray().getItems()) {
                        let kv = Jsons.text(e)
                        let eq = idxOf(kv, "=")
                        if (eq > 0) {
                            let k = kv[..eq]
                            if (k != "PATH" && k != "LANG" && k != "HOSTNAME" && k != "HOME") {
                                ins.extraEnv.add(k, kv[eq + 1..])
                            }
                        }
                    }
                }
            case None => ()
        }
        // 命中模板：套用版本/存档路径/Mod 目录约定（dataDir/mountPath 保持 inspect 结果）
        match (Games.find(game)) {
            case Some(tpl) =>
                if (tpl.versions.size > 0) {
                    ins.version = tpl.versions[0].key
                } else {
                    ins.version = "imported"
                }
            case None => ()
        }
        if (ins.dataDir == "") {
            ins.dataDir = Paths.instanceDir(ins.id)
        }
        Store.update({ d => d.instances.add(ins) })
        return None
    }

    static func parseFirst(text: String): ?JsonObject {
        try {
            let v = JsonValue.fromStr(text)
            if (HttpUtil.kindIs(v, JsonKind.JsArray)) {
                let items = v.asArray().getItems()
                if (items.size > 0 && HttpUtil.kindIs(items[0], JsonKind.JsObject)) {
                    return Some(items[0].asObject())
                }
            }
            if (HttpUtil.kindIs(v, JsonKind.JsObject)) {
                return Some(v.asObject())
            }
            return None
        } catch (_: Exception) {
            return None
        }
    }

    static func getObj(o: JsonObject, key: String): ?JsonObject {
        match (o.get(key)) {
            case Some(v) =>
                if (HttpUtil.kindIs(v, JsonKind.JsObject)) {
                    return Some(v.asObject())
                }
                return None
            case None => return None
        }
    }
}

/* ---------------- REST 路由 ---------------- */

public func registerImportRoutes(): Unit {
    router.post("/api/v1/instances/import", { ctx, _ =>
        if (!Auth.guard(ctx) || !Auth.allowAdmin(ctx)) {
            return
        }
        let body = HttpUtil.bodyJson(ctx)
        let container = HttpUtil.str(body, "container", "")
        let name = HttpUtil.str(body, "name", "")
        match (Importer.doImport(container, name)) {
            case None =>
                match (Auth.current(ctx)) {
                    case Some(s) => Users.audit(s.username, "导入容器 ${container}")
                    case None => ()
                }
                if (Docker.status(container.trimAscii()) == "running") {
                    match (Store.data().findInstance(container.trimAscii())) {
                        case Some(ins) => ConsolePipe.attach(ins)
                        case None => ()
                    }
                }
                HttpUtil.okMsg(ctx, "已导入容器 ${container}（不影响运行状态）")
            case Some(err) => HttpUtil.fail(ctx, 6001, err)
        }
    })
}
