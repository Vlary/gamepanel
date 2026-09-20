package gamepanel

/*
 * 单元测试：cjpm test 运行。
 * 覆盖面板最容易出错的三块纯逻辑：cron 表达式、百分号解码、路径安全。
 */

import std.unittest.*
import stdx.encoding.json.*
import std.unittest.testmacro.*
import std.time.*
import std.fs.*
import std.collection.*

func isNone<T>(o: ?T): Bool {
    match (o) {
        case None => true
        case Some(_) => false
    }
}

@Test
func testCronParseBasic(): Unit {
    // 标准五段
    @Assert(!isNone(Cron.parse("0 4 * * *")))
    @Assert(!isNone(Cron.parse("*/30 * * * *")))
    @Assert(!isNone(Cron.parse("0 */6 * * *")))
    @Assert(!isNone(Cron.parse("30 22 1,15 * *")))
    @Assert(!isNone(Cron.parse("10-20/5 8-18 1 1 1-5")))
}

@Test
func testCronParseIllegal(): Unit {
    @Assert(isNone(Cron.parse("60 * * * *")))     // 分钟越界
    @Assert(isNone(Cron.parse("* 24 * * *")))     // 小时越界
    @Assert(isNone(Cron.parse("* * 0 * *")))      // 日越界
    @Assert(isNone(Cron.parse("* * * 13 *")))     // 月越界
    @Assert(isNone(Cron.parse("* * * * 7")))      // 周越界
    @Assert(isNone(Cron.parse("abc")))            // 非数字
    @Assert(isNone(Cron.parse("1 2 3")))          // 段数不足
    @Assert(isNone(Cron.parse("* * * * */0")))    // 步长非法
}

@Test
func testCronMatches(): Unit {
    let c = Cron.parse("30 4 * * *") ?? Cron.parse("* * * * *") ?? return
    // 2026-09-21 04:30:00 周一 -> 命中
    let hit = DateTime.parse("2026-09-21 04:30:00", "yyyy-MM-dd HH:mm:ss")
    @Assert(c.matches(hit))
    // 05:30 不命中（小时）
    let miss1 = DateTime.parse("2026-09-21 05:30:00", "yyyy-MM-dd HH:mm:ss")
    @Assert(!c.matches(miss1))
    // 04:31 不命中（分钟）
    let miss2 = DateTime.parse("2026-09-21 04:31:00", "yyyy-MM-dd HH:mm:ss")
    @Assert(!c.matches(miss2))
}

@Test
func testCronStepEveryFiveMinutes(): Unit {
    let c = Cron.parse("*/5 * * * *") ?? return
    let h1 = DateTime.parse("2026-09-21 10:05:00", "yyyy-MM-dd HH:mm:ss")
    @Assert(c.matches(h1))
    let h2 = DateTime.parse("2026-09-21 10:07:00", "yyyy-MM-dd HH:mm:ss")
    @Assert(!c.matches(h2))
}

@Test
func testCronNextAfter(): Unit {
    let c = Cron.parse("0 4 * * *") ?? return
    let from = DateTime.parse("2026-09-20 12:00:00", "yyyy-MM-dd HH:mm:ss")
    match (c.nextAfter(from)) {
        case Some(next) =>
            let expect = "2026-09-21 04:00"
            @Assert(next.format("yyyy-MM-dd HH:mm") == expect)
        case None => @Assert(false)
    }
}

@Test
func testPercentDecodePlain(): Unit {
    @Assert(percentDecode("test-note.txt") == "test-note.txt")
    @Assert(percentDecode("hello") == "hello")
}

@Test
func testPercentDecodeEncoded(): Unit {
    // "中文" 的 UTF-8 百分号编码
    @Assert(percentDecode("%E4%B8%AD%E6%96%87") == "中文")
    // 混合
    @Assert(percentDecode("a%20b.txt") == "a b.txt")
    // 非法序列原样保留
    @Assert(percentDecode("100%zz") == "100%zz")
}

@Test
func testSafeJoinBlocksEscape(): Unit {
    // 临时目录作为 base
    let base = "/tmp/gp-test-safety"
    if (exists(base)) {
        remove(base, recursive: true)
    }
    Directory.create(base, recursive: true)
    Directory.create(base + "/world", recursive: true)
    File.writeTo(base + "/world/level.dat", "x".toArray())
    // 正常子路径
    match (FileManager.safeJoin(base, "world/level.dat")) {
        case Some(p) => @Assert(p.startsWith(base))
        case None => @Assert(false)
    }
    // 不存在的目标文件：父目录校验通过，返回拼接路径
    match (FileManager.safeJoin(base, "new-file.txt")) {
        case Some(p) => @Assert(p == base + "/new-file.txt")
        case None => @Assert(false)
    }
    // 逃逸被拒
    match (FileManager.safeJoin(base, "../../etc/passwd")) {
        case Some(_) => @Assert(false)
        case None => @Assert(true)
    }
    // 相对逃逸被拒
    match (FileManager.safeJoin(base, "a/../../../etc")) {
        case Some(_) => @Assert(false)
        case None => @Assert(true)
    }
    // base 自身
    match (FileManager.safeJoin(base, "")) {
        case Some(p) => @Assert(p == base)
        case None => @Assert(false)
    }
}

@Test
func testJsonHelpers(): Unit {
    let o = Jsons.obj([("name", JsonString("面板")), ("port", JsonInt(25565)), ("on", JsonBool(true))])
    @Assert(o.size() == 3)
    match (o.get("name")) {
        case Some(v) => @Assert(Jsons.text(v) == "面板")
        case None => @Assert(false)
    }
    // 往返：序列化再解析
    let round = JsonValue.fromStr(o.toJsonString()).asObject()
    match (round.get("port")) {
        case Some(v) => @Assert(v.asInt().getValue() == 25565)
        case None => @Assert(false)
    }
}

@Test
func testMimeOf(): Unit {
    @Assert(mimeOf("/x/y/style.css").contains("text/css"))
    @Assert(mimeOf("/x/app.js").contains("javascript"))
    @Assert(mimeOf("/x/a.html").contains("text/html"))
    @Assert(mimeOf("/x/noext") == "application/octet-stream")
}

@Test
func testInstanceJsonRoundtrip(): Unit {
    let ins = Instance()
    ins.id = "gp-test"
    ins.name = "回环测试"
    ins.game = "minecraft"
    ins.ports.add("25565:25565")
    ins.env.add("EULA", "TRUE")
    ins.extraEnv.add("FOO", "BAR")
    ins.memoryMB = 4096
    let back = Instance.fromJson(ins.toJson())
    @Assert(back.id == ins.id)
    @Assert(back.name == "回环测试")
    @Assert(back.ports.size == 1)
    @Assert((back.env.get("EULA") ?? "") == "TRUE")
    @Assert((back.extraEnv.get("FOO") ?? "") == "BAR")
    @Assert(back.memoryMB == 4096)
}


@Test
func testWriteProperties(): Unit {
    let text = "#Minecraft server properties\n#Mon Sep 20\ndifficulty=easy\nmotd=A Minecraft Server\n"
    let out = GameConfig.writePropertiesForTest(text, "difficulty", "hard")
    println("输出: [${out}]")
    @Assert(out.contains("difficulty=hard"))
    @Assert(out.contains("motd=A Minecraft Server"))
    // 必须保留真实换行（曾因字面 \n 把整个文件压成一行导致替换失效）
    @Assert(out.split("\n").size >= 3)
    @Assert(out.contains("#Minecraft server properties"))
    // 不存在的键 -> 追加
    let out2 = GameConfig.writePropertiesForTest(text, "new-key", "1")
    @Assert(out2.contains("new-key=1"))
    @Assert(out2.contains("difficulty=easy"))
}


@Test
func testGameConfigIniAndJson(): Unit {
    let dir = "/tmp/gp-cfg-test"
    if (exists(dir)) {
        remove(dir, recursive: true)
    }
    Directory.create(dir, recursive: true)
    let ins = Instance()
    ins.id = "gp-cfg-test"
    ins.dataDir = dir
    ins.mountPath = "/data"
    // ini：已有段内替换 + 新段追加
    let iniField = ConfigField("cluster.ini", "ini", "GAMEPLAY.game_mode", "模式", "text", [], "survival", "")
    File.writeTo(dir + "/cluster.ini", "[NETWORK]\nmax_players=6\n\n[GAMEPLAY]\ngame_mode=survival\npvp=false\n".toArray())
    let err1 = GameConfig.writeField(ins, iniField, "endless")
    @Assert(err1 == None)
    let text = String.fromUtf8(File.readFrom(dir + "/cluster.ini"))
    @Assert(text.contains("game_mode=endless"))
    @Assert(text.contains("pvp=false"))
    @Assert(text.contains("max_players=6"))
    // ini 新段
    let iniField2 = ConfigField("cluster.ini", "ini", "MISC.tick_rate", "tick", "number", [], "15", "")
    @Assert(GameConfig.writeField(ins, iniField2, "30") == None)
    let text2 = String.fromUtf8(File.readFrom(dir + "/cluster.ini"))
    @Assert(text2.contains("[MISC]"))
    @Assert(text2.contains("tick_rate=30"))
    // json：类型保持（int 写 int）
    let jsonField = ConfigField("config.json", "json", "Settings.MaxSlots", "槽位", "number", [], "8", "")
    File.writeTo(dir + "/config.json", "{\"Settings\":{\"MaxSlots\":8,\"AutoSave\":true}}".toArray())
    @Assert(GameConfig.writeField(ins, jsonField, "30") == None)
    let jtext = String.fromUtf8(File.readFrom(dir + "/config.json"))
    @Assert(jtext.contains("MaxSlots") && jtext.contains("30"))
    @Assert(!jtext.contains("30\""))   // 数字类型保持，不变字符串
    @Assert(jtext.contains("AutoSave") && jtext.contains("true"))
    remove(dir, recursive: true)
}


@Test
func testGuessGame(): Unit {
    @Assert(Importer.guessGame("itzg/minecraft-server:latest") == "minecraft")
    @Assert(Importer.guessGame("jamesits/dst-server") == "dst")
    @Assert(Importer.guessGame("ryshe/terraria:latest") == "terraria")
    @Assert(Importer.guessGame("renegademw/zomboid-dedicated-server") == "zomboid")
    @Assert(Importer.guessGame("nginx:alpine") == "custom")
    // 大小写不敏感
    @Assert(Importer.guessGame("MyCraft/Minecraft-Server") == "minecraft")
}


@Test
func testWorkshopAddRemove(): Unit {
    let dir = "/tmp/gp-ws-test"
    if (exists(dir)) {
        remove(dir, recursive: true)
    }
    Directory.create(dir, recursive: true)
    // DST：台账 + setup.lua 追加/移除
    let dst = Instance()
    dst.id = "gp-ws-test"
    dst.game = "dst"
    dst.dataDir = dir
    Directory.create(dir + "/mods")
    @Assert(workshopAdd(dst, "3795506590", "测试Mod", "") == None)
    let lua = dir + "/mods/dedicated_server_mods_setup.lua"
    @Assert(exists(lua))
    let text = String.fromUtf8(File.readFrom(lua))
    @Assert(text.contains("ServerModSetup(\"3795506590\")"))
    // 重复添加被拒
    @Assert(workshopAdd(dst, "3795506590", "x", "") != None)
    // 移除：setup.lua 行与台账都清掉
    workshopRemove(dst, "3795506590")
    let text2 = String.fromUtf8(File.readFrom(lua))
    @Assert(!text2.contains("3795506590"))
    @Assert(loadWorkshop(dst).size == 0)
    remove(dir, recursive: true)
}

@Test
func testPzWorkshopIni(): Unit {
    let dir = "/tmp/gp-pz-test"
    if (exists(dir)) {
        remove(dir, recursive: true)
    }
    Directory.create(dir, recursive: true)
    let pz = Instance()
    pz.id = "gp-pz-test"
    pz.game = "zomboid"
    pz.dataDir = dir
    Directory.create(dir + "/Server")
    File.writeTo(dir + "/Server/servertest.ini", "[servertest]\nMaxPlayers=32\n".toArray())
    // 添加：WorkshopItems 与 Mods 追加
    @Assert(workshopAdd(pz, "2706a", "", "MyMod") == None)
    let f = ConfigField("Server/servertest.ini", "ini", "servertest.WorkshopItems", "", "text", [], "", "")
    let (v, ok) = GameConfig.readField(dir, f)
    @Assert(ok)
    @Assert(v == "2706a")
    let f2 = ConfigField("Server/servertest.ini", "ini", "servertest.Mods", "", "text", [], "", "")
    let (v2, _) = GameConfig.readField(dir, f2)
    @Assert(v2 == "MyMod")
    // 第二个追加为逗号列表
    @Assert(workshopAdd(pz, "999b", "", "OtherMod") == None)
    let (v3, _) = GameConfig.readField(dir, f)
    @Assert(v3 == "2706a,999b")
    // 移除一个，剩另一个
    workshopRemove(pz, "2706a")
    let (v4, _) = GameConfig.readField(dir, f)
    @Assert(v4 == "999b")
    // 原有键不受影响
    let fMax = ConfigField("Server/servertest.ini", "ini", "servertest.MaxPlayers", "", "text", [], "", "")
    let (vm, _) = GameConfig.readField(dir, fMax)
    @Assert(vm == "32")
    remove(dir, recursive: true)
}


@Test
func testUserPasswordHash(): Unit {
    // 同 salt 同密码 -> 哈希确定；不同 salt -> 不同哈希；64 位十六进制
    let h1 = Users.hashPassword("secret123", "abc")
    let h2 = Users.hashPassword("secret123", "abc")
    let h3 = Users.hashPassword("secret123", "xyz")
    @Assert(h1 == h2)
    @Assert(h1 != h3)
    @Assert(h1.size == 64)
    @Assert(Users.hashPassword("wrong", "abc") != h1)
}

@Test
func testRoleLevel(): Unit {
    @Assert(roleLevel("admin") > roleLevel("operator"))
    @Assert(roleLevel("operator") > roleLevel("viewer"))
    @Assert(roleLevel("unknown") == 0)
}

@Test
func testParseTraffic(): Unit {
    // easytier-cli peer 表 rx/tx 列的单位解析（统一换算为 KB）
    @Assert(EasyTier.parseTraffic("0 B") == 0.0)
    let kb = EasyTier.parseTraffic("4.87 kB")
    @Assert(kb > 4.86 && kb < 4.88)
    @Assert(EasyTier.parseTraffic("1.00 MB") == 1024.0)
    @Assert(EasyTier.parseTraffic("2.00 GB") == 2.0 * 1024.0 * 1024.0)
    // 512 B -> 0.5 KB
    let b = EasyTier.parseTraffic("512 B")
    @Assert(b > 0.499 && b < 0.501)
    // 无数据标记
    @Assert(EasyTier.parseTraffic("-") == -1.0)
    @Assert(EasyTier.parseTraffic("") == -1.0)
    @Assert(EasyTier.parseTraffic("abc") == -1.0)
}

@Test
func testStripMask(): Unit {
    @Assert(EasyTier.stripMask("10.6.6.2/24") == "10.6.6.2")
    @Assert(EasyTier.stripMask("10.6.6.2") == "10.6.6.2")
    @Assert(EasyTier.stripMask("") == "")
}
