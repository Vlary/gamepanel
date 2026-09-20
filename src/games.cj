package gamepanel

/*
 * 游戏模板：定义"一款游戏怎么开服"的全部静态知识。
 * 面板内置 Minecraft / 饥荒联机版 / 泰拉瑞亚 / 僵尸毁灭工程 四款，
 * 模板结构统一，扩展新游戏只需在 all() 里加一项。
 */

import std.collection.*
import stdx.encoding.json.*

public class GameVersion {
    public GameVersion(let key: String, let label: String, let image: String, let env: Array<(String, String)>) {}
}

/* 游戏配置项：指向数据目录内某个配置文件的一个键。
   format: properties | ini | json
   path:   properties 为键名；ini 为 "段名.键名"；json 为点路径 */
public class ConfigField {
    public ConfigField(
        let file: String,
        let format: String,
        let path: String,
        let label: String,
        let kind: String,                       // text | number | toggle | select
        let options: Array<(String, String)>,   // select 的 (值, 标签)
        let def: String,
        let help: String
    ) {}
}

public class GameTemplate {
    public GameTemplate(
        let key: String,           // 模板标识
        let title: String,         // 展示名
        let icon: String,          // emoji 图标
        let desc: String,          // 一句话说明
        let image: String,         // 默认镜像
        let mountPath: String,     // 容器内数据目录
        let ports: Array<String>,  // 默认端口映射 "宿主:容器/协议"
        let baseEnv: Array<(String, String)>, // 基础环境变量
        let versions: Array<GameVersion>,     // 可选版本
        let savePaths: Array<String>,         // 存档相对路径（快照只打包这些）
        let modsDir: String,       // Mod 目录（相对数据目录）
        let note: String,          // 创建时的重要提示
        let configFields: Array<ConfigField>   // 游戏专属配置项
    ) {}

    public func findVersion(key: String): ?GameVersion {
        for (v in versions) {
            if (v.key == key) {
                return Some(v)
            }
        }
        return None
    }
}

func fieldsJson(fields: Array<ConfigField>): JsonArray {
    let arr = JsonArray()
    for (f in fields) {
        let opts = JsonArray()
        for ((v, label) in f.options) {
            opts.add(Jsons.obj([("value", JsonString(v)), ("label", JsonString(label))]))
        }
        arr.add(Jsons.obj([
            ("file", JsonString(f.file)),
            ("format", JsonString(f.format)),
            ("path", JsonString(f.path)),
            ("label", JsonString(f.label)),
            ("kind", JsonString(f.kind)),
            ("options", opts),
            ("default", JsonString(f.def)),
            ("help", JsonString(f.help))
        ]))
    }
    return arr
}

public class Games {
    private static let allTemplates = ArrayList<GameTemplate>()

    static init() {
        /* ---------------- Minecraft（itzg 社区镜像，Paper/Forge/Fabric 全支持） ---------------- */
        allTemplates.add(GameTemplate(
            "minecraft", "Minecraft", "⛏",
            "沙盒建造之王，Paper 高性能核心适合多人服",
            "itzg/minecraft-server:latest",
            "/data",
            ["25565:25565"],
            [("EULA", "TRUE"), ("RCON_ENABLED", "TRUE"), ("RCON_PASSWORD", "gamepanel")],
            [
                GameVersion("paper-1.21", "Paper 1.21.1（推荐）", "itzg/minecraft-server:latest", [("TYPE", "PAPER"), ("VERSION", "1.21.1")]),
                GameVersion("paper-1.20", "Paper 1.20.6", "itzg/minecraft-server:latest", [("TYPE", "PAPER"), ("VERSION", "1.20.6")]),
                GameVersion("vanilla-1.21", "原版 1.21.1", "itzg/minecraft-server:latest", [("TYPE", "VANILLA"), ("VERSION", "1.21.1")]),
                GameVersion("forge-1.20", "Forge 1.20.1（模组服）", "itzg/minecraft-server:latest", [("TYPE", "FORGE"), ("VERSION", "1.20.1")]),
                GameVersion("fabric-1.21", "Fabric 1.21.1（轻量模组）", "itzg/minecraft-server:latest", [("TYPE", "FABRIC"), ("VERSION", "1.21.1")])
            ],
            ["world"],
            "mods",
            "创建即代表接受 Minecraft EULA；首次启动需下载核心文件，耐心等待日志出现 Done",
            [
                ConfigField("server.properties", "properties", "difficulty", "游戏难度", "select",
                    [("peaceful", "和平"), ("easy", "简单"), ("normal", "普通"), ("hard", "困难")], "easy", "修改后重启实例生效"),
                ConfigField("server.properties", "properties", "gamemode", "默认模式", "select",
                    [("survival", "生存"), ("creative", "创造"), ("adventure", "冒险"), ("spectator", "旁观")], "survival", ""),
                ConfigField("server.properties", "properties", "max-players", "最大玩家数", "number", [], "20", ""),
                ConfigField("server.properties", "properties", "view-distance", "视距（区块）", "number", [], "10", "越大越流畅消耗越少但看得越近；8~12 常用"),
                ConfigField("server.properties", "properties", "online-mode", "正版验证", "toggle", [], "true", "关闭可允许离线账号（安全风险自负）"),
                ConfigField("server.properties", "properties", "white-list", "开启白名单", "toggle", [], "false", "开启后仅白名单内玩家可进"),
                ConfigField("server.properties", "properties", "pvp", "允许 PVP", "toggle", [], "true", ""),
                ConfigField("server.properties", "properties", "motd", "服务器欢迎语 MOTD", "text", [], "A GamePanel Server", "")
            ]
        ))

        /* ---------------- 饥荒联机版（SteamCMD 官方服务器 + 地面/洞穴双 shard） ---------------- */
        allTemplates.add(GameTemplate(
            "dst", "饥荒联机版", "🔥",
            "Klei 官方专用服务器，支持地面 + 洞穴双世界",
            "jamesits/dst-server:latest",
            "/data",
            ["10999:10999/udp"],
            [],
            [
                GameVersion("latest", "最新正式版（含洞穴）", "jamesits/dst-server:latest", [])
            ],
            ["storage"],
            "mods",
            "必须到 Klei 账户页申请集群令牌（Cluster Token）后填入 extraEnv 的 DST_CLUSTER_TOKEN 才能开服",
            [
                ConfigField("storage/cluster.ini", "ini", "GAMEPLAY.game_mode", "游戏模式", "select",
                    [("survival", "生存"), ("endless", "无尽"), ("wilderness", "荒野")], "survival", ""),
                ConfigField("storage/cluster.ini", "ini", "GAMEPLAY.pvp", "允许 PVP", "toggle", [], "false", ""),
                ConfigField("storage/cluster.ini", "ini", "GAMEPLAY.pause_when_empty", "无人时暂停", "toggle", [], "true", ""),
                ConfigField("storage/cluster.ini", "ini", "NETWORK.max_players", "最大玩家数", "number", [], "6", "饥荒建议 ≤ 10"),
                ConfigField("storage/cluster.ini", "ini", "NETWORK.cluster_name", "服务器名称", "text", [], "GamePanel DST", "客户端服务器列表里显示的名字"),
                ConfigField("storage/cluster.ini", "ini", "NETWORK.cluster_description", "服务器描述", "text", [], "", "")
            ]
        ))

        /* ---------------- 泰拉瑞亚（TShock 服务端） ---------------- */
        allTemplates.add(GameTemplate(
            "terraria", "泰拉瑞亚", "🌳",
            "2D 冒险建造，TShock 服务端支持插件与权限管理",
            "ryshe/terraria:latest",
            "/root/.local/share/Terraria/Worlds",
            ["7777:7777"],
            [("TZ", "Asia/Shanghai"), ("WORLD_NAME", "gamepanel-world"), ("WORLD_FILENAME", "gamepanel-world.wld"), ("MAX_PLAYERS", "16")],
            [
                GameVersion("tshock-latest", "TShock 最新版 / 泰拉瑞亚 1.4.x（推荐）", "ryshe/terraria:latest", []),
                GameVersion("tshock-5", "TShock 5.x 指定版", "ryshe/terraria:latest", [("TSHOCK_VERSION", "5")])
            ],
            ["."],
            "ServerPlugins",
            "世界自动生成并保存在数据目录；TShock 插件放入 ServerPlugins 后重启生效；默认世界名 gamepanel-world 可在环境变量里改",
            [
                ConfigField("config.json", "json", "Settings.MaxSlots", "最大玩家槽位", "number", [], "8", ""),
                ConfigField("config.json", "json", "Settings.ReservedSlots", "预留槽位（管理员）", "number", [], "20", ""),
                ConfigField("config.json", "json", "Settings.ServerPassword", "进服密码", "text", [], "", "留空为无密码"),
                ConfigField("config.json", "json", "Settings.AutoSave", "自动存档", "toggle", [], "true", ""),
                ConfigField("config.json", "json", "Settings.BackupInterval", "自动备份间隔（分钟）", "number", [], "10", "")
            ]
        ))

        /* ---------------- 僵尸毁灭工程（PZ 专用服务器） ---------------- */
        allTemplates.add(GameTemplate(
            "zomboid", "僵尸毁灭工程", "🧟",
            "硬核末日生存，LinuxGSM 官方方案专用服务器",
            "afey/zomboid:latest",
            "/server-data",
            ["16261:16261/udp", "16262:16262"],
            [("TZ", "Asia/Shanghai")],
            [
                GameVersion("latest", "最新正式版 (Build 41)", "afey/zomboid:latest", [])
            ],
            ["Server"],
            "mods",
            "建议在 extraEnv 设置 ADMIN_PASSWORD（管理面板密码）与 SERVER_NAME；存档在 Server/ 目录",
            [
                ConfigField("Server/servertest.ini", "ini", "servertest.MaxPlayers", "最大玩家数", "number", [], "32", ""),
                ConfigField("Server/servertest.ini", "ini", "servertest.Password", "进服密码", "text", [], "", "留空为无密码"),
                ConfigField("Server/servertest.ini", "ini", "servertest.Open", "好友可见", "toggle", [], "false", "true=出现在服务器列表"),
                ConfigField("Server/servertest.ini", "ini", "servertest.Public", "公网服务器列表", "toggle", [], "false", "true=对全世界公开")
            ]
        ))
    }

    public static func find(key: String): ?GameTemplate {
        for (t in allTemplates) {
            if (t.key == key) {
                return Some(t)
            }
        }
        return None
    }

    /* 各游戏 Mod 生态：来源（modrinth|steam|url）与搜索外链（{q} 为关键词占位）。
       不同游戏生态不同：MC 在 Modrinth；饥荒/PZ 在 Steam 创意工坊（服务器按 ID 自动下载）；
       泰拉瑞亚 TShock 插件分散在官方论坛/GitHub，走直链下载。 */
    public static func modSourceOf(game: String): (String, String) {
        match (game) {
            case "minecraft" => return ("modrinth", "https://modrinth.com/mods?q={q}")
            case "dst" => return ("steam", "https://steamcommunity.com/workshop/browse/?appid=322330&searchtext={q}")
            case "zomboid" => return ("steam", "https://steamcommunity.com/workshop/browse/?appid=108600&searchtext={q}")
            case "terraria" => return ("url", "https://github.com/search?q=tshock+plugin&type=repositories")
            case _ => return ("url", "")
        }
    }

    public static func all(): ArrayList<GameTemplate> {
        return allTemplates
    }

    /* 模板列表 JSON（供前端创建向导） */
    public static func listJson(): JsonArray {
        let arr = JsonArray()
        for (t in allTemplates) {
            let vers = JsonArray()
            for (v in t.versions) {
                vers.add(Jsons.obj([
                    ("key", JsonString(v.key)),
                    ("label", JsonString(v.label))
                ]))
            }
            let envObj = JsonObject()
            for ((k, v) in t.baseEnv) {
                envObj.put(k, JsonString(v))
            }
            arr.add(Jsons.obj([
                ("key", JsonString(t.key)),
                ("title", JsonString(t.title)),
                ("icon", JsonString(t.icon)),
                ("desc", JsonString(t.desc)),
                ("mountPath", JsonString(t.mountPath)),
                ("ports", Jsons.arr(arrStr(t.ports))),
                ("baseEnv", envObj),
                ("versions", vers),
                ("savePaths", Jsons.arr(arrStr(t.savePaths))),
                ("modsDir", JsonString(t.modsDir)),
                ("modSource", JsonString(modSourceOf(t.key)[0])),
                ("modSearchUrl", JsonString(modSourceOf(t.key)[1])),
                ("note", JsonString(t.note)),
                ("configFields", fieldsJson(t.configFields))
            ]))
        }
        return arr
    }

    private static func arrStr(items: Array<String>): Array<JsonValue> {
        let out = Array<JsonValue>(items.size, repeat: JsonNull())
        for (i in 0..items.size) {
            out[i] = JsonString(items[i])
        }
        return out
    }
}
