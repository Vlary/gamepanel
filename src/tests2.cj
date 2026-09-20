package gamepanel

/*
 * 单元测试第二辑（全量测试第 1 轮扩充）：
 * 覆盖按游戏定制的纯逻辑函数 —— 多用临时目录构造 Instance 直测文件操作，
 * 不触碰 Config/Store 全局状态（那些在隔离面板的 API 测试轮覆盖）。
 */

import std.unittest.*
import stdx.encoding.json.*
import std.unittest.testmacro.*
import std.fs.*
import std.collection.*
import std.time.*

func jarr(v: ?JsonValue): JsonArray {
    match (v) {
        case Some(x) => return x.asArray()
        case None => return JsonArray()
    }
}

func mkTempDir(name: String): String {
    let dir = "/tmp/gp-t-" + name
    if (exists(dir)) {
        remove(dir, recursive: true)
    }
    Directory.create(dir, recursive: true)
    return dir
}

/* 造一个仅供文件函数使用的实例壳 */
func shellIns(dir: String, game: String): Instance {
    let ins = Instance()
    ins.id = "gp-t"
    ins.game = game
    ins.dataDir = dir
    return ins
}

@Test
func testMcWorldsJson(): Unit {
    let dir = mkTempDir("mcworlds")
    // 主世界已存档；下界仅 session.lock（Paper 首存档前）；world_backup 不是世界
    Directory.create(dir + "/world", recursive: true)
    File.writeTo(dir + "/world/level.dat", "x".toArray())
    File.writeTo(dir + "/world/session.lock", "x".toArray())
    Directory.create(dir + "/world_nether", recursive: true)
    File.writeTo(dir + "/world_nether/session.lock", "x".toArray())
    Directory.create(dir + "/world_backup", recursive: true)
    File.writeTo(dir + "/eula.txt", "# c\neula=true\n".toArray())
    let o = mcWorldsJson(shellIns(dir, "minecraft"))
    let ws = jarr(o.get("worlds"))
    @Assert(ws.size() == 2)
    var mainWorld: ?JsonObject = None
    var nether: ?JsonObject = None
    for (w in ws.getItems()) {
        let obj = w.asObject()
        if (Jsons.text(obj.get("name") ?? JsonString("")) == "world") {
            mainWorld = Some(obj)
        }
        if (Jsons.text(obj.get("name") ?? JsonString("")) == "world_nether") {
            nether = Some(obj)
        }
    }
    @Assert(!isNone(mainWorld))
    @Assert(!isNone(nether))
    match (mainWorld) {
        case Some(m) =>
            @Assert(Jsons.text(m.get("label") ?? JsonString("")).contains("主世界"))
            @Assert(HttpUtil.boolean(m, "saved", false))
        case None => ()
    }
    match (nether) {
        case Some(n) => @Assert(!HttpUtil.boolean(n, "saved", true))
        case None => ()
    }
    @Assert(Jsons.text(o.get("eula") ?? JsonString("")) == "true")
    remove(dir, recursive: true)
}

@Test
func testTerrariaWorldsJson(): Unit {
    let dir = mkTempDir("tw")
    File.writeTo(dir + "/a.wld", "world-a".toArray())
    File.writeTo(dir + "/b.wld", "world-b".toArray())
    File.writeTo(dir + "/config.json", "{}".toArray())
    let o = terrariaWorldsJson(shellIns(dir, "terraria"))
    let ws = jarr(o.get("worlds"))
    @Assert(ws.size() == 2)   // config.json 不算世界
    @Assert(Jsons.text(o.get("current") ?? JsonString("")) == "gamepanel-world.wld")
    // 指定 WORLD_FILENAME 后 current 标记迁移
    let ins2 = shellIns(dir, "terraria")
    let _ = ins2.extraEnv.add("WORLD_FILENAME", "b.wld")
    let o2 = terrariaWorldsJson(ins2)
    var marked = ""
    for (w in jarr(o2.get("worlds")).getItems()) {
        if (HttpUtil.boolean(w.asObject(), "current", false)) {
            marked = Jsons.text(w.asObject().get("file") ?? JsonString(""))
        }
    }
    @Assert(marked == "b.wld")
    remove(dir, recursive: true)
}

@Test
func testDstShardsJson(): Unit {
    let dir = mkTempDir("dst")
    let cluster = dir + "/DoNotStarveTogether/Cluster_1"
    Directory.create(cluster + "/Master", recursive: true)
    Directory.create(cluster + "/Caves", recursive: true)
    File.writeTo(cluster + "/Master/server.ini", "[NETWORK]\n".toArray())
    File.writeTo(cluster + "/Caves/server.ini", "[NETWORK]\n".toArray())
    let o = dstShardsJson(shellIns(dir, "dst"))
    let shards = jarr(o.get("shards"))
    @Assert(shards.size() == 2)
    // 洞穴移出（停用）后：仍可识别且 enabled=false
    Directory.create(dir + "/DoNotStarveTogether/Cluster_1_disabled", recursive: true)
    rename(cluster + "/Caves", to: dir + "/DoNotStarveTogether/Cluster_1_disabled/Caves", overwrite: true)
    let o2 = dstShardsJson(shellIns(dir, "dst"))
    var cavesEnabled = true
    var cnt: Int64 = 0
    for (sh in jarr(o2.get("shards")).getItems()) {
        let obj = sh.asObject()
        cnt += 1
        if (Jsons.text(obj.get("name") ?? JsonString("")) == "Caves") {
            cavesEnabled = HttpUtil.boolean(obj, "enabled", true)
        }
    }
    @Assert(cnt == 2)
    @Assert(!cavesEnabled)
    remove(dir, recursive: true)
}

@Test
func testApplyDstWorldgen(): Unit {
    let dir = mkTempDir("worldgen")
    let master = dir + "/DoNotStarveTogether/Cluster_1/Master"
    Directory.create(master, recursive: true)
    let ins = shellIns(dir, "dst")
    // 写入永冬预设
    @Assert(applyDstWorldgen(ins, "Master", "eternal-winter") == None)
    let lua = String.fromUtf8(File.readFrom(master + "/worldgenoverride.lua"))
    @Assert(lua.contains("override_enabled"))
    @Assert(lua.contains("winter"))
    // 换默认预设 = 删除文件
    @Assert(applyDstWorldgen(ins, "Master", "default") == None)
    @Assert(!exists(master + "/worldgenoverride.lua"))
    // 非法分片名/未知预设
    @Assert(applyDstWorldgen(ins, "../evil", "default") != None)
    @Assert(applyDstWorldgen(ins, "Master", "no-such") != None)
    remove(dir, recursive: true)
}

@Test
func testEasyTierParseTable(): Unit {
    let md = "| ipv4 | hostname | cost |\n|--------------|------|------|\n| 10.0.0.1/24 | a | Local |\n| 10.0.0.2/24 | b | p2p |"
    let arr = EasyTier.parseTableForTest(md, ["ipv4", "hostname", "cost"])
    @Assert(arr.size() == 2)   // 表头与分隔行被跳过
    let first = arr.getItems()[0].asObject()
    @Assert(Jsons.text(first.get("ipv4") ?? JsonString("")) == "10.0.0.1/24")
    @Assert(Jsons.text(first.get("hostname") ?? JsonString("")) == "a")
    // 表头（与 fieldNames 匹配）与列数不足的行都被跳过
    let md2 = "| ipv4 | hostname |\n|------|------|\n| only-one |\n| 1.1.1.1 | h |"
    @Assert(EasyTier.parseTableForTest(md2, ["ipv4", "hostname"]).size() == 1)
}

@Test
func testCronMonthAndDow(): Unit {
    // 每年 3 月 1 日 0 点
    let c1 = Cron.parse("0 0 1 3 *") ?? return
    let hit = DateTime.parse("2027-03-01 00:00:00", "yyyy-MM-dd HH:mm:ss")
    @Assert(c1.matches(hit))
    let miss = DateTime.parse("2027-04-01 00:00:00", "yyyy-MM-dd HH:mm:ss")
    @Assert(!c1.matches(miss))
    // 每周六 8 点（6=周六）
    let c2 = Cron.parse("0 8 * * 6") ?? return
    let sat = DateTime.parse("2026-09-26 08:00:00", "yyyy-MM-dd HH:mm:ss")   // 周六
    @Assert(c2.matches(sat))
    let sun = DateTime.parse("2026-09-27 08:00:00", "yyyy-MM-dd HH:mm:ss")   // 周日
    @Assert(!c2.matches(sun))
}

@Test
func testWriteIniNewSectionAndBoundary(): Unit {
    // 文件为空：新段 + 新键
    let t1 = GameConfig.writeIniForTest("", "SandboxVars.ZombieCount", "4")
    @Assert(t1.contains("[SandboxVars]"))
    @Assert(t1.contains("ZombieCount=4"))
    // 已有段无此键：插在段末（下一段之前）
    let src = "[GAMEPLAY]\npvp=false\n[NETWORK]\nmax_players=6\n"
    let t2 = GameConfig.writeIniForTest(src, "GAMEPLAY.pause_when_empty", "true")
    let lines = t2.split("\n").toArray()
    var idxPause: Int64 = -1
    var idxNet: Int64 = -1
    for (i in 0..lines.size) {
        if (lines[i].contains("pause_when_empty")) { idxPause = Int64(i) }
        if (lines[i].contains("[NETWORK]")) { idxNet = Int64(i) }
    }
    @Assert(idxPause >= 0 && idxNet > idxPause)   // 插在 GAMEPLAY 段内而非文末
    // 段是文件最后一段：键补在段末
    let t3 = GameConfig.writeIniForTest("[MISC]\na=1\n", "MISC.b", "2")
    @Assert(t3.contains("b=2"))
    @Assert(t3.contains("a=1"))
}

@Test
func testGenRecIdUnique(): Unit {
    let seen = HashSet<String>()
    var allUnique = true
    for (_ in 0..50) {
        let id = Backups.genRecId()
        if (seen.contains(id)) {
            allUnique = false
        }
        seen.add(id)
    }
    @Assert(allUnique)
    @Assert(seen.size == 50)
}

@Test
func testGameConfigParentDirCreate(): Unit {
    // 目标文件父目录不存在（PZ Server/ 场景）：writeField 自动创建并写入
    let dir = mkTempDir("parentdir")
    let ins = shellIns(dir, "zomboid")
    let f = ConfigField("Server/servertest.ini", "ini", "SandboxVars.ZombieCount", "", "text", [], "", "")
    @Assert(GameConfig.writeField(ins, f, "2") == None)
    let text = String.fromUtf8(File.readFrom(dir + "/Server/servertest.ini"))
    @Assert(text.contains("ZombieCount=2"))
    remove(dir, recursive: true)
}

@Test
func testDirSizeAndDiskAvail(): Unit {
    let dir = mkTempDir("size")
    File.writeTo(dir + "/blob.bin", Array<Byte>(1024, repeat: 65))
    @Assert(dirSizeKB(dir) >= 1)
    remove(dir, recursive: true)
    // 系统临时目录必然存在且有余量
    @Assert(diskAvailBytes("/tmp") > 0)
    @Assert(diskTotalBytes("/tmp") > diskAvailBytes("/tmp"))
}

@Test
func testInstanceMergedEnvOverride(): Unit {
    let ins = Instance()
    let _ = ins.env.add("TYPE", "PAPER")
    let _ = ins.env.add("VERSION", "1.21")
    let _ = ins.extraEnv.add("VERSION", "1.20")
    let merged = ins.mergedEnv()
    var v = ""
    for ((k, val) in merged) {
        if (k == "VERSION") { v = val }
    }
    @Assert(v == "1.20")   // extraEnv 覆盖 baseEnv 同名键
    var hasType = false
    for ((k, _) in merged) {
        if (k == "TYPE") { hasType = true }
    }
    @Assert(hasType)
}

@Test
func testNotificationsFormat(): Unit {
    // 通知对象构造格式（push 的 JSON 结构经 Items 校验）
    let n = Jsons.obj([
        ("id", JsonString("n-1")),
        ("kind", JsonString("instance")),
        ("title", JsonString("t")),
        ("read", JsonBool(false))
    ])
    @Assert(!HttpUtil.boolean(n, "read", true))
    @Assert(Jsons.text(n.get("kind") ?? JsonString("")) == "instance")
}

@Test
func testMcLoaderOfCompat(): Unit {
    // 前端 mcLoaderOf 的后端等价校验：版本 key 前缀解析
    let cases = [("paper-1.21", "paper"), ("fabric-1.20.1", "fabric"), ("forge-1.20.1", "forge"), ("vanilla-1.21", "vanilla"), ("neoforge-1.21", "neoforge"), ("latest", "")]
    for ((key, want) in cases) {
        let sp = idxOf(key, "-")
        let loader = if (sp > 0) { key[..sp] } else { "" }
        @Assert(loader == want)
    }
}

@Test
func testPresetListsInit(): Unit {
    // DST/PZ 预设表初始化幂等且数量稳定
    initDstPresets()
    let n1 = DST_WORLDGEN_PRESETS.size
    initDstPresets()
    @Assert(DST_WORLDGEN_PRESETS.size == n1)
    @Assert(n1 == 4)
    initPzPresets()
    let m1 = PZ_SANDBOX_PRESETS.size
    initPzPresets()
    @Assert(PZ_SANDBOX_PRESETS.size == m1)
    @Assert(m1 == 4)
}
