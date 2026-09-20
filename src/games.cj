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
   path:   properties 为键名；ini 为 "段名.键名"；json 为点路径
   group:  前端分组标题（同组字段聚合渲染，默认"通用"） */
public class ConfigField {
    public var group = "通用"
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

    /* 带分组的便捷构造 */
    public init(file: String, format: String, path: String, label: String,
        kind: String, options: Array<(String, String)>, def: String, help: String, group: String) {
        this(file, format, path, label, kind, options, def, help)
        this.group = group
    }
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
                GameVersion("paper-1.19", "Paper 1.19.4（怀旧插件生态）", "itzg/minecraft-server:latest", [("TYPE", "PAPER"), ("VERSION", "1.19.4")]),
                GameVersion("paper-1.16", "Paper 1.16.5（离线朋克生态）", "itzg/minecraft-server:latest", [("TYPE", "PAPER"), ("VERSION", "1.16.5")]),
                GameVersion("paper-1.12", "Paper 1.12.2（经典圈地服）", "itzg/minecraft-server:latest", [("TYPE", "PAPER"), ("VERSION", "1.12.2")]),
                GameVersion("vanilla-1.21", "原版 1.21.1", "itzg/minecraft-server:latest", [("TYPE", "VANILLA"), ("VERSION", "1.21.1")]),
                GameVersion("vanilla-1.20", "原版 1.20.6", "itzg/minecraft-server:latest", [("TYPE", "VANILLA"), ("VERSION", "1.20.6")]),
                GameVersion("forge-1.21", "Forge 1.21.1（模组服）", "itzg/minecraft-server:latest", [("TYPE", "FORGE"), ("VERSION", "1.21.1")]),
                GameVersion("forge-1.20", "Forge 1.20.1（模组服）", "itzg/minecraft-server:latest", [("TYPE", "FORGE"), ("VERSION", "1.20.1")]),
                GameVersion("fabric-1.21", "Fabric 1.21.1（轻量模组）", "itzg/minecraft-server:latest", [("TYPE", "FABRIC"), ("VERSION", "1.21.1")]),
                GameVersion("fabric-1.20", "Fabric 1.20.1（轻量模组）", "itzg/minecraft-server:latest", [("TYPE", "FABRIC"), ("VERSION", "1.20.1")]),
                GameVersion("fabric-1.16", "Fabric 1.16.5（老牌模组生态）", "itzg/minecraft-server:latest", [("TYPE", "FABRIC"), ("VERSION", "1.16.5")])
            ],
            ["world"],
            "mods",
            "创建即代表接受 Minecraft EULA；首次启动需下载核心文件，耐心等待日志出现 Done",
            [
                // ---- 基础设置 ----
                ConfigField("server.properties", "properties", "motd", "服务器欢迎语 MOTD", "text", [], "A GamePanel Server", "服务器列表里显示的简介，支持 § 颜色代码", "基础设置"),
                ConfigField("server.properties", "properties", "max-players", "最大玩家数", "number", [], "20", "", "基础设置"),
                ConfigField("server.properties", "properties", "difficulty", "游戏难度", "select",
                    [("peaceful", "和平"), ("easy", "简单"), ("normal", "普通"), ("hard", "困难")], "easy", "修改后重启实例生效", "基础设置"),
                ConfigField("server.properties", "properties", "gamemode", "默认模式", "select",
                    [("survival", "生存"), ("creative", "创造"), ("adventure", "冒险"), ("spectator", "旁观")], "survival", "", "基础设置"),
                ConfigField("server.properties", "properties", "resource-pack", "资源包 URL", "text", [], "", "玩家进服自动下载的资源包直链（可空）", "基础设置"),
                // ---- 游戏性 ----
                ConfigField("server.properties", "properties", "pvp", "允许 PVP", "toggle", [], "true", "", "游戏性"),
                ConfigField("server.properties", "properties", "allow-flight", "允许飞行", "toggle", [], "false", "创造/旁观不受限；生存开作弊飞行需开启", "游戏性"),
                ConfigField("server.properties", "properties", "enable-command-block", "启用命令方块", "toggle", [], "false", "地图/整合包常需要", "游戏性"),
                ConfigField("server.properties", "properties", "spawn-monsters", "生成敌对生物", "toggle", [], "true", "关闭即无僵尸骷髅（建筑服常用）", "游戏性"),
                ConfigField("server.properties", "properties", "spawn-animals", "生成动物", "toggle", [], "true", "", "游戏性"),
                ConfigField("server.properties", "properties", "allow-nether", "允许下界传送门", "toggle", [], "true", "", "游戏性"),
                ConfigField("server.properties", "properties", "force-gamemode", "锁定加入者模式", "toggle", [], "false", "进服强制回到默认模式（清掉创造权限）", "游戏性"),
                // ---- 性能优化 ----
                ConfigField("server.properties", "properties", "view-distance", "视距（区块）", "number", [], "10", "客户端可见范围；性能吃紧先降到 8", "性能优化"),
                ConfigField("server.properties", "properties", "simulation-distance", "模拟距离（区块）", "number", [], "10", "生物/红石活动范围；可低于视距省性能", "性能优化"),
                ConfigField("server.properties", "properties", "network-compression-threshold", "网络压缩阈值（字节）", "number", [], "256", "0=全压缩，-1=关闭；256 常用", "性能优化"),
                ConfigField("server.properties", "properties", "max-tick-time", "单刻超时（毫秒）", "number", [], "60000", "超时强制崩掉卡死的世界，-1 关闭", "性能优化"),
                ConfigField("server.properties", "properties", "sync-chunk-writes", "区块同步落盘", "toggle", [], "true", "关闭可提速但断电风险略增（HDD 建议 true）", "性能优化"),
                // ---- 安全 ----
                ConfigField("server.properties", "properties", "online-mode", "正版验证", "toggle", [], "true", "关闭可允许离线账号（安全风险自负）", "安全"),
                ConfigField("server.properties", "properties", "white-list", "开启白名单", "toggle", [], "false", "开启后仅白名单内玩家可进（玩家页可批量加白）", "安全"),
                ConfigField("server.properties", "properties", "spawn-protection", "出生点半径保护", "number", [], "16", "0=关闭；仅 OP 可在此范围破坏", "安全"),
                ConfigField("server.properties", "properties", "enforce-secure-profile", "强制安全档案", "toggle", [], "true", "聊天签名校验，离线服需关闭", "安全"),
                ConfigField("server.properties", "properties", "prevent-proxy-connections", "拦截代理连接", "toggle", [], "false", "", "安全")
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
            ["DoNotStarveTogether/Cluster_1"],
            "DoNotStarveTogether/Cluster_1/mods",
            "必须到 Klei 账户页申请集群令牌（Cluster Token）后填入 extraEnv 的 DST_CLUSTER_TOKEN 才能开服",
            [
                // ---- 服务器信息 ----
                ConfigField("DoNotStarveTogether/Cluster_1/cluster.ini", "ini", "NETWORK.cluster_name", "服务器名称", "text", [], "GamePanel DST", "客户端服务器列表里显示的名字", "服务器信息"),
                ConfigField("DoNotStarveTogether/Cluster_1/cluster.ini", "ini", "NETWORK.cluster_description", "服务器描述", "text", [], "", "列表里名称下方的简介", "服务器信息"),
                ConfigField("DoNotStarveTogether/Cluster_1/cluster.ini", "ini", "NETWORK.cluster_password", "进服密码", "text", [], "", "留空则无密码", "服务器信息"),
                ConfigField("DoNotStarveTogether/Cluster_1/cluster.ini", "ini", "NETWORK.cluster_language", "服务器语言", "select",
                    [("zh", "中文"), ("en", "英文"), ("auto", "自动")], "zh", "影响客户端列表的地区筛选", "服务器信息"),
                // ---- 游戏性 ----
                ConfigField("DoNotStarveTogether/Cluster_1/cluster.ini", "ini", "GAMEPLAY.game_mode", "游戏模式", "select",
                    [("survival", "生存"), ("endless", "无尽"), ("wilderness", "荒野")], "survival", "无尽模式无复活上限（复活雕像），适合长线经营", "游戏性"),
                ConfigField("DoNotStarveTogether/Cluster_1/cluster.ini", "ini", "GAMEPLAY.pvp", "允许 PVP", "toggle", [], "false", "", "游戏性"),
                ConfigField("DoNotStarveTogether/Cluster_1/cluster.ini", "ini", "GAMEPLAY.pause_when_empty", "无人时暂停", "toggle", [], "true", "开启省资源且时间不流逝", "游戏性"),
                ConfigField("DoNotStarveTogether/Cluster_1/cluster.ini", "ini", "GAMEPLAY.vote_enabled", "允许玩家投票踢人", "toggle", [], "true", "", "游戏性"),
                ConfigField("DoNotStarveTogether/Cluster_1/cluster.ini", "ini", "GAMEPLAY.autosaver", "自动存档器", "toggle", [], "true", "游戏内每天自动保存", "游戏性"),
                ConfigField("DoNotStarveTogether/Cluster_1/cluster.ini", "ini", "GAMEPLAY.max_wildfires", "野火上限", "number", [], "15", "防夏季野火蔓延烧家", "游戏性"),
                // ---- 网络 ----
                ConfigField("DoNotStarveTogether/Cluster_1/cluster.ini", "ini", "NETWORK.max_players", "最大玩家数", "number", [], "6", "饥荒建议 ≤ 10", "网络"),
                ConfigField("DoNotStarveTogether/Cluster_1/cluster.ini", "ini", "NETWORK.tick_rate", "同步频率（Hz）", "number", [], "15", "15=官方默认；30 更流畅但更耗带宽", "网络"),
                ConfigField("DoNotStarveTogether/Cluster_1/cluster.ini", "ini", "NETWORK.whitelist_slots", "白名单预留位", "number", [], "0", "为白名单玩家保留的连接位", "网络"),
                ConfigField("DoNotStarveTogether/Cluster_1/cluster.ini", "ini", "NETWORK.cluster_intention", "服务器意图标签", "select",
                    [("cooperative", "合作"), ("social", "社交"), ("competitive", "竞争"), ("madness", "疯狂")], "cooperative", "列表筛选用", "网络")
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
                // ---- 服务器信息 ----
                ConfigField("config.json", "json", "Settings.ServerName", "服务器名称", "text", [], "", "客户端服务器列表显示", "服务器信息"),
                ConfigField("config.json", "json", "Settings.ServerPassword", "进服密码", "text", [], "", "留空为无密码", "服务器信息"),
                ConfigField("config.json", "json", "Settings.MaxSlots", "最大玩家槽位", "number", [], "8", "", "服务器信息"),
                ConfigField("config.json", "json", "Settings.ReservedSlots", "预留槽位（管理员）", "number", [], "20", "", "服务器信息"),
                ConfigField("config.json", "json", "Settings.Language", "服务器语言码", "number", [], "1", "1=英语 2=德语 3=意大利语 4=法语 5=西语 7=俄语 8=简中", "服务器信息"),
                // ---- 游戏性 ----
                ConfigField("config.json", "json", "Settings.AutoSave", "自动存档", "toggle", [], "true", "", "游戏性"),
                ConfigField("config.json", "json", "Settings.BackupInterval", "自动备份间隔（分钟）", "number", [], "10", "0=关闭", "游戏性"),
                ConfigField("config.json", "json", "Settings.BackupKeepFor", "备份保留时长（小时）", "number", [], "48", "", "游戏性"),
                ConfigField("config.json", "json", "Settings.DisableHardcore", "关闭硬核模式", "toggle", [], "false", "开启后死亡不掉档重生", "游戏性"),
                ConfigField("config.json", "json", "Settings.DisableDeflatePriority", "关闭传送优先级", "toggle", [], "false", "", "游戏性"),
                ConfigField("config.json", "json", "Settings.ForcedDifficulty", "强制难度", "select",
                    [("0", "跟随世界"), ("1", "经典"), ("2", "专家"), ("3", "大师"), ("4", "旅行")], "0", "覆盖加入玩家的难度请求", "游戏性"),
                // ---- 安全与维护 ----
                ConfigField("config.json", "json", "Settings.ProtectSpawn", "出生点保护半径", "number", [], "50", "0=关闭；防止家门口被拆", "安全与维护"),
                ConfigField("config.json", "json", "Settings.RegionOnlyPvP", "仅 PVP 区域开战", "toggle", [], "false", "", "安全与维护"),
                ConfigField("config.json", "json", "Settings.IgnoreChestPermissions", "忽略箱子权限", "toggle", [], "false", "开启=所有人可开箱子（信任服适用）", "安全与维护"),
                ConfigField("config.json", "json", "Settings.AllowForbiddenItems", "允许违禁物品命令", "toggle", [], "false", "/give 等管理命令发放特殊物品", "安全与维护"),
                ConfigField("config.json", "json", "Settings.LogRestores", "记录世界恢复", "toggle", [], "false", "排查回档纠纷用", "安全与维护"),
                ConfigField("config.json", "json", "Settings.BufferPackets", "封包缓冲上限", "number", [], "512", "网络异常掉线时可调大", "安全与维护")
            ]
        ))

        /* ---------------- 僵尸毁灭工程（PZ 专用服务器） ---------------- */
        allTemplates.add(GameTemplate(
            "zomboid", "僵尸毁灭工程", "🧟",
            "硬核末日生存，LinuxGSM 官方方案专用服务器",
            "afey/zomboid:latest",
            "/server-data",
            ["16261:16261/udp", "16262:16262"],
            [("TZ", "Asia/Shanghai"), ("LGSM_GAMESERVER", "pzserver"), ("LGSM_GAMESERVER_UPDATE", "true")],
            [
                GameVersion("latest", "最新正式版 (Build 41)", "afey/zomboid:latest", [])
            ],
            ["Server"],
            "mods",
            "LGSM 自动安装并更新服务端（首次启动需下载数 GB，耐心等待）；存档与配置在 Server/ 目录，管理员密码在下方游戏配置里设置",
            [
                // ---- 服务器信息 ----
                ConfigField("Server/servertest.ini", "ini", "servertest.PublicName", "服务器名称", "text", [], "", "公网列表里显示的名字", "服务器信息"),
                ConfigField("Server/servertest.ini", "ini", "servertest.PublicDescription", "服务器描述", "text", [], "", "", "服务器信息"),
                ConfigField("Server/servertest.ini", "ini", "servertest.Password", "进服密码", "text", [], "", "留空为无密码", "服务器信息"),
                ConfigField("Server/servertest.ini", "ini", "servertest.AdminPassword", "管理员密码", "text", [], "", "游戏内开启管理面板（权限设置）用", "服务器信息"),
                ConfigField("Server/servertest.ini", "ini", "servertest.MaxPlayers", "最大玩家数", "number", [], "32", "", "服务器信息"),
                ConfigField("Server/servertest.ini", "ini", "servertest.Open", "好友可见", "toggle", [], "false", "true=出现在 Steam 好友的服务器列表", "服务器信息"),
                ConfigField("Server/servertest.ini", "ini", "servertest.Public", "公网服务器列表", "toggle", [], "false", "true=对全世界公开（需公网 IP）", "服务器信息"),
                ConfigField("Server/servertest.ini", "ini", "servertest.AutoCreateUserOnWhiteList", "白名单即注册", "toggle", [], "false", "进服即自动加入白名单（仅密码服适用）", "服务器信息"),
                // ---- 游戏性 ----
                ConfigField("Server/servertest.ini", "ini", "servertest.PVP", "允许 PVP", "toggle", [], "false", "", "游戏性"),
                ConfigField("Server/servertest.ini", "ini", "servertest.PauseEmpty", "无人时暂停", "toggle", [], "true", "省资源且时间不流逝", "游戏性"),
                ConfigField("Server/servertest.ini", "ini", "servertest.NoDanger", "关闭危险事件", "toggle", [], "false", "直升机/Meta 事件不再触发", "游戏性"),
                ConfigField("Server/servertest.ini", "ini", "servertest.SafetySystem", "安全屋系统", "toggle", [], "true", "玩家可宣称安全屋，丧尸不破门", "游戏性"),
                ConfigField("Server/servertest.ini", "ini", "servertest.ShowSafety", "显示安全屋提示", "toggle", [], "true", "", "游戏性"),
                ConfigField("Server/servertest.ini", "ini", "servertest.SleepAllowed", "允许睡觉跳时", "toggle", [], "false", "单人/好友联机可开，公服慎开", "游戏性"),
                ConfigField("Server/servertest.ini", "ini", "servertest.SleepNeeded", "睡觉需在床上", "toggle", [], "true", "", "游戏性"),
                ConfigField("Server/servertest.ini", "ini", "servertest.PlayerSafehouse", "玩家自建安全屋", "toggle", [], "false", "所有玩家均可占领安全屋", "游戏性"),
                // ---- 存档与维护 ----
                ConfigField("Server/servertest.ini", "ini", "servertest.SaveWorldEveryMinutes", "世界保存间隔（分钟）", "number", [], "30", "", "存档与维护"),
                ConfigField("Server/servertest.ini", "ini", "servertest.BackupOnOchestratorClose", "关服时自动备份", "toggle", [], "false", "每次关服前多存一份", "存档与维护"),
                ConfigField("Server/servertest.ini", "ini", "servertest.DoChecksumScan", "进服文件校验", "toggle", [], "false", "开启后客户端改动文件会被踢，防作弊", "存档与维护"),
                ConfigField("Server/servertest.ini", "ini", "servertest.AntiCheatProtectionType", "反作弊等级", "select",
                    [("1", "标准"), ("2", "推荐增强"), ("3", "最严格")], "1", "", "存档与维护"),
                ConfigField("Server/servertest.ini", "ini", "servertest.MaxAccounts", "账号数上限", "number", [], "0", "0=不限；限制单 IP 注册数", "存档与维护")
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
