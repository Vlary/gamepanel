package gamepanel

/*
 * 数据模型与 JSON 互转。
 * 存储采用"手工序列化"而非 stdx.serialization 的 DataModel 机制：
 * 字段显式列出，读写路径一目了然，排查问题不需要理解框架层。
 */

import stdx.encoding.json.*
import std.convert.*
import std.collection.*

/* dataDir 绝对 -> 相对（以 dataRoot 为基准；不在其下则原样） */
func relDataDir(abs: String): String {
    let root = Config.dataRoot
    if (abs.startsWith(root + "/")) {
        return abs[root.size + 1..]
    }
    return abs
}

/* 一个游戏服务器实例 */
public class Instance {
    public var id = ""                 // gp-xxxxxx
    public var name = ""               // 展示名
    public var game = ""               // minecraft / dst / terraria / zomboid / custom
    public var version = ""            // 模板版本 key，见 games.cj
    public var image = ""              // docker 镜像
    public var dataDir = ""            // 宿主机数据目录（bind mount 源）
    public var mountPath = ""          // 容器内挂载点
    public var ports = ArrayList<String>()     // ["25565:25565"] 宿主:容器
    public var env = HashMap<String, String>() // 传给容器的基础环境变量（EULA/TYPE 等）
    public var extraEnv = HashMap<String, String>() // 用户自定义环境变量
    public var memoryMB: Int64 = 2048  // --memory
    public var cpus: Float64 = 0.0     // --cpus，0 = 不限制
    public var autoStart = true        // 随面板/宿主机自启（--restart unless-stopped）
    public var node = "local"          // 所在节点（docker context 名；local=本机）
    public var useMesh = false         // 接入 EasyTier 组网（共享组网容器网络栈，游戏监听虚拟 IP）
    public var createdAt = ""

    public init() {}

    public func containerName(): String {
        return id
    }

    /* 环境变量合并：模板基础 + 用户自定义（自定义优先） */
    public func mergedEnv(): HashMap<String, String> {
        let out = HashMap<String, String>()
        for ((k, v) in env) {
            out.add(k, v)
        }
        for ((k, v) in extraEnv) {
            out.add(k, v)
        }
        return out
    }

    public func toJson(): JsonObject {
        let portsArr = JsonArray()
        for (p in ports) {
            portsArr.add(JsonString(p))
        }
        let envObj = JsonObject()
        for ((k, v) in env) {
            envObj.put(k, JsonString(v))
        }
        let extraObj = JsonObject()
        for ((k, v) in extraEnv) {
            extraObj.put(k, JsonString(v))
        }
        return Jsons.obj([
            ("id", JsonString(id)),
            ("name", JsonString(name)),
            ("game", JsonString(game)),
            ("version", JsonString(version)),
            ("image", JsonString(image)),
            // 存相对路径（相对 dataRoot），数据目录整体迁移后实例不失效
            ("dataDir", JsonString(relDataDir(dataDir))),
            ("mountPath", JsonString(mountPath)),
            ("ports", portsArr),
            ("env", envObj),
            ("extraEnv", extraObj),
            ("memoryMB", JsonInt(memoryMB)),
            ("cpus", JsonFloat(cpus)),
            ("autoStart", JsonBool(autoStart)),
            ("node", JsonString(node)),
            ("useMesh", JsonBool(useMesh)),
            ("createdAt", JsonString(createdAt))
        ])
    }

    public static func fromJson(o: JsonObject): Instance {
        let ins = Instance()
        ins.id = HttpUtil.str(o, "id", "")
        ins.name = HttpUtil.str(o, "name", "")
        ins.game = HttpUtil.str(o, "game", "")
        ins.version = HttpUtil.str(o, "version", "")
        ins.image = HttpUtil.str(o, "image", "")
        let stored = HttpUtil.str(o, "dataDir", "")
        if (stored.startsWith("/")) {
            ins.dataDir = stored
        } else if (stored != "") {
            ins.dataDir = Config.dataRoot + "/" + stored
        } else {
            ins.dataDir = ""
        }
        ins.mountPath = HttpUtil.str(o, "mountPath", "")
        match (o.get("ports")) {
            case Some(v) =>
                if (HttpUtil.kindIs(v, JsonKind.JsArray)) {
                    for (item in v.asArray().getItems()) {
                        ins.ports.add(Jsons.text(item))
                    }
                }
            case None => ()
        }
        loadEnv(o, "env", ins.env)
        loadEnv(o, "extraEnv", ins.extraEnv)
        ins.memoryMB = HttpUtil.int(o, "memoryMB", 2048)
        match (o.get("cpus")) {
            case Some(v) =>
                if (HttpUtil.kindIs(v, JsonKind.JsFloat)) {
                    ins.cpus = v.asFloat().getValue()
                } else if (HttpUtil.kindIs(v, JsonKind.JsInt)) {
                    ins.cpus = Float64.parse(v.asInt().getValue().toString())
                }
            case None => ()
        }
        ins.autoStart = HttpUtil.boolean(o, "autoStart", true)
        ins.node = HttpUtil.str(o, "node", "local")
        ins.useMesh = HttpUtil.boolean(o, "useMesh", false)
        ins.createdAt = HttpUtil.str(o, "createdAt", "")
        return ins
    }

    private static func loadEnv(o: JsonObject, key: String, out: HashMap<String, String>) {
        match (o.get(key)) {
            case Some(v) =>
                if (HttpUtil.kindIs(v, JsonKind.JsObject)) {
                    for ((k, item) in v.asObject().getFields()) {
                        out.add(k, Jsons.text(item))
                    }
                }
            case None => ()
        }
    }
}

/* 计划任务：到点触发一个动作 */
public class TaskItem {
    public var id = ""
    public var instanceId = ""     // 关联实例（动作针对它执行）
    public var name = ""
    public var cron = ""           // 五段 cron：分 时 日 月 周
    public var action = ""         // backup | snapshot | restart | start | stop | command
    public var command = ""        // action=command 时发送到服务器控制台
    public var enabled = true
    public var keepCount: Int64 = 7 // action=backup/snapshot 时保留份数
    public var createdAt = ""
    public var lastRun = ""
    public var nextRun = ""

    public init() {}

    public func toJson(): JsonObject {
        return Jsons.obj([
            ("id", JsonString(id)),
            ("instanceId", JsonString(instanceId)),
            ("name", JsonString(name)),
            ("cron", JsonString(cron)),
            ("action", JsonString(action)),
            ("command", JsonString(command)),
            ("enabled", JsonBool(enabled)),
            ("keepCount", JsonInt(keepCount)),
            ("createdAt", JsonString(createdAt)),
            ("lastRun", JsonString(lastRun)),
            ("nextRun", JsonString(nextRun))
        ])
    }

    public static func fromJson(o: JsonObject): TaskItem {
        let t = TaskItem()
        t.id = HttpUtil.str(o, "id", "")
        t.instanceId = HttpUtil.str(o, "instanceId", "")
        t.name = HttpUtil.str(o, "name", "")
        t.cron = HttpUtil.str(o, "cron", "")
        t.action = HttpUtil.str(o, "action", "")
        t.command = HttpUtil.str(o, "command", "")
        t.enabled = HttpUtil.boolean(o, "enabled", true)
        t.keepCount = HttpUtil.int(o, "keepCount", 7)
        t.createdAt = HttpUtil.str(o, "createdAt", "")
        t.lastRun = HttpUtil.str(o, "lastRun", "")
        t.nextRun = HttpUtil.str(o, "nextRun", "")
        return t
    }
}

/* 备份/快照记录（type 字段区分） */
public class BackupRec {
    public var id = ""
    public var instanceId = ""
    public var kind = "backup"   // backup=全量目录快照 | snapshot=仅存档目录
    public var name = ""
    public var file = ""         // tar.gz 绝对路径
    public var sizeBytes: Int64 = 0
    public var auto = false      // 计划任务产生
    public var createdAt = ""

    public init() {}

    public func toJson(): JsonObject {
        return Jsons.obj([
            ("id", JsonString(id)),
            ("instanceId", JsonString(instanceId)),
            ("kind", JsonString(kind)),
            ("name", JsonString(name)),
            ("file", JsonString(file)),
            ("sizeBytes", JsonInt(sizeBytes)),
            ("auto", JsonBool(auto)),
            ("createdAt", JsonString(createdAt))
        ])
    }

    public static func fromJson(o: JsonObject): BackupRec {
        let r = BackupRec()
        r.id = HttpUtil.str(o, "id", "")
        r.instanceId = HttpUtil.str(o, "instanceId", "")
        r.kind = HttpUtil.str(o, "kind", "backup")
        r.name = HttpUtil.str(o, "name", "")
        r.file = HttpUtil.str(o, "file", "")
        r.sizeBytes = HttpUtil.int(o, "sizeBytes", 0)
        r.auto = HttpUtil.boolean(o, "auto", false)
        r.createdAt = HttpUtil.str(o, "createdAt", "")
        return r
    }
}
