package gamepanel

/*
 * 多节点：基于 docker context 的远程节点管理。
 * 节点 = 一条预配置的 docker context（宿主机上 `docker context create <名> --docker "host=ssh://user@主机"`
 * 即可接入），实例绑定节点后，其全部容器命令经该 context 在远端执行。
 * 存储：nodes.json
 */

import stdx.net.http.*
import stdx.encoding.json.*
import std.fs.*
import std.collection.*
import std.sync.*
import std.process.*

public class NodeInfo {
    public var name = ""
    public var note = ""
    public init() {}
}

public class Nodes {
    private static let m = Mutex()

    static func file(): String {
        return Config.dataRoot + "/nodes.json"
    }

    static func lock() { m.lock() }
    static func unlock() { m.unlock() }

    public static func load(): ArrayList<NodeInfo> {
        let list = ArrayList<NodeInfo>()
        let local = NodeInfo()
        local.name = "local"
        local.note = "本机 Docker"
        list.add(local)
        if (!exists(file())) {
            return list
        }
        try {
            let v = JsonValue.fromStr(String.fromUtf8(File.readFrom(file())))
            if (HttpUtil.kindIs(v, JsonKind.JsArray)) {
                for (item in v.asArray().getItems()) {
                    if (!HttpUtil.kindIs(item, JsonKind.JsObject)) {
                        continue
                    }
                    let o = item.asObject()
                    let n = NodeInfo()
                    n.name = Jsons.text(o.get("name") ?? JsonString(""))
                    n.note = Jsons.text(o.get("note") ?? JsonString(""))
                    if (n.name != "" && n.name != "local") {
                        list.add(n)
                    }
                }
            }
        } catch (_: Exception) {
            ()
        }
        return list
    }

    static func saveRemote(list: ArrayList<NodeInfo>): Unit {
        let arr = JsonArray()
        for (n in list) {
            if (n.name == "local") {
                continue
            }
            arr.add(Jsons.obj([("name", JsonString(n.name)), ("note", JsonString(n.note))]))
        }
        File.writeTo(file(), arr.toJsonString().toArray())
    }

    /* 校验 context 可用：docker --context X version */
    public static func probe(name: String): ?String {
        let r = Docker.run(["version", "--format", "{{.Server.Version}}"], node: name)
        if (r.ok() && r.stdout.trimAscii() != "") {
            return Some(r.stdout.trimAscii())
        }
        return None
    }

    public static func add(name: String, note: String): ?String {
        if (name == "" || name == "local") {
            return Some("节点名非法")
        }
        let list = load()
        for (n in list) {
            if (n.name == name) {
                return Some("节点已存在")
            }
        }
        // context 必须先在宿主机配置好
        let (code, _, _) = Process.runOutput("docker", ["context", "inspect", name])
        if (code != 0) {
            return Some("宿主机上不存在 docker context「${name}」，请先执行: docker context create ${name} --docker \"host=ssh://user@主机\"")
        }
        let n = NodeInfo()
        n.name = name
        n.note = note
        list.add(n)
        saveRemote(list)
        return None
    }

    public static func remove(name: String): ?String {
        if (name == "local") {
            return Some("local 节点不可删除")
        }
        // 有实例绑定则拒绝
        for (ins in Store.data().instances) {
            if (ins.node == name) {
                return Some("仍有实例「${ins.name}」绑定该节点")
            }
        }
        let list = load()
        let keep = ArrayList<NodeInfo>()
        for (n in list) {
            if (n.name != name) {
                keep.add(n)
            }
        }
        saveRemote(keep)
        return None
    }

    public static func listJson(): JsonArray {
        let arr = JsonArray()
        for (n in load()) {
            var used: Int64 = 0
            for (ins in Store.data().instances) {
                if (ins.node == n.name) {
                    used += 1
                }
            }
            var ver = ""
            match (probe(n.name)) {
                case Some(v) => ver = v
                case None => ver = ""
            }
            arr.add(Jsons.obj([
                ("name", JsonString(n.name)),
                ("note", JsonString(n.note)),
                ("instances", JsonInt(used)),
                ("dockerVersion", JsonString(ver))
            ]))
        }
        return arr
    }
}


/* ---------------- REST（admin） ---------------- */

public func registerNodeRoutes(): Unit {
    router.get("/api/v1/nodes", { ctx, _ =>
        if (!Auth.guard(ctx)) {
            return
        }
        HttpUtil.ok(ctx, Nodes.listJson())
    })

    router.post("/api/v1/nodes", { ctx, _ =>
        if (!Auth.guard(ctx) || !Auth.allowAdmin(ctx)) {
            return
        }
        let body = HttpUtil.bodyJson(ctx)
        match (Nodes.add(HttpUtil.str(body, "name", "").trimAscii(), HttpUtil.str(body, "note", ""))) {
            case None =>
                match (Auth.current(ctx)) {
                    case Some(s) => Users.audit(s.username, "添加节点 ${HttpUtil.str(body, "name", "")}")
                    case None => ()
                }
                HttpUtil.okMsg(ctx, "节点已添加")
            case Some(e) => HttpUtil.fail(ctx, 7101, e)
        }
    })

    router.delete("/api/v1/nodes/{name}", { ctx, md =>
        if (!Auth.guard(ctx) || !Auth.allowAdmin(ctx)) {
            return
        }
        match (Nodes.remove(md.matchString("name"))) {
            case None =>
                match (Auth.current(ctx)) {
                    case Some(s) => Users.audit(s.username, "移除节点 ${md.matchString("name")}")
                    case None => ()
                }
                HttpUtil.okMsg(ctx, "节点已移除")
            case Some(e) => HttpUtil.fail(ctx, 7102, e)
        }
    })
}
