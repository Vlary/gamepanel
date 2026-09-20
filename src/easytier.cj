package gamepanel

/*
 * EasyTier 组网集成（P0）：
 *  - 面板托管一个特权容器运行 easytier-core（host 网络 + TUN），复用容器管理思路
 *  - 两种模式：host（开 listener 供玩家直连，可配端口避冲突）
 *              join（--no-listener 纯 -p 客户端挂接已有网络，与系统级 EasyTier 零冲突共存）
 *  - 状态查询经 docker exec easytier-cli（markdown 表格解析，不依赖宿主二进制）
 *  - 邀请卡：网络名 + 密钥 + 全部可达地址 + 一键加入命令
 * 配置存储：data/et.json
 */

import stdx.net.http.*
import stdx.encoding.json.*
import std.sync.*
import std.time.*
import std.fs.*
import std.collection.*
import std.convert.*
import std.process.*

let ET_CONTAINER = "gp-easytier"
let ET_IMAGE = "easytier/easytier:latest"

/* peer 表字段顺序（easytier-cli 输出列） */
let ET_PEER_FIELDS = ["ipv4", "hostname", "cost", "latency_ms", "loss", "rx", "tx", "tunnel_proto", "nat_type", "version"]

public class EasyTier {
    /* ---------------- 配置 ---------------- */

    static func configFile(): String {
        return Config.dataRoot + "/et.json"
    }

    public static func loadConfig(): JsonObject {
        if (!exists(configFile())) {
            return Jsons.obj([("enabled", JsonBool(false))])
        }
        try {
            let v = JsonValue.fromStr(String.fromUtf8(File.readFrom(configFile())))
            if (HttpUtil.kindIs(v, JsonKind.JsObject)) {
                return v.asObject()
            }
        } catch (_: Exception) {
            ()
        }
        return Jsons.obj([("enabled", JsonBool(false))])
    }

    static func saveConfig(o: JsonObject): Unit {
        File.writeTo(configFile(), o.toJsonString().toArray())
    }

    static func cfgStr(o: JsonObject, k: String, def: String): String {
        return Jsons.text(o.get(k) ?? JsonString(def))
    }

    /* ---------------- 容器生命周期 ---------------- */

    public static func apply(o: JsonObject): ?String {
        let networkName = cfgStr(o, "networkName", "").trimAscii()
        let secret = cfgStr(o, "secret", "").trimAscii()
        if (networkName == "" || secret == "") {
            return Some("网络名与密钥不能为空")
        }
        let mode = cfgStr(o, "mode", "join")   // host | join
        let rpcPort = cfgStr(o, "rpcPort", "15890")
        let args = ArrayList<String>(["run", "-d", "--name", ET_CONTAINER,
            "--network", "host",
            "--cap-add", "NET_ADMIN",
            "--restart", "unless-stopped"])
        if (exists("/dev/net/tun")) {
            args.add("--device")
            args.add("/dev/net/tun")
        }
        args.add(ET_IMAGE)
        args.add("--network-name")
        args.add(networkName)
        args.add("--network-secret")
        args.add(secret)
        args.add("--hostname")
        args.add("gamepanel")
        args.add("-r")
        args.add("127.0.0.1:${rpcPort}")
        if (mode == "join") {
            args.add("--no-listener")   // 纯客户端挂接：不监听任何端口，可与系统级 EasyTier 共存
        } else {
            let tcpPort = cfgStr(o, "tcpPort", "11010")
            let udpOn = HttpUtil.boolean(o, "udpEnabled", true)
            args.add("-l")
            args.add("tcp://0.0.0.0:${tcpPort}")
            if (udpOn) {
                args.add("-l")
                args.add("udp://0.0.0.0:${tcpPort}")
            }
        }
        match (o.get("peers")) {
            case Some(v) =>
                if (HttpUtil.kindIs(v, JsonKind.JsArray)) {
                    for (p in v.asArray().getItems()) {
                        let addr = Jsons.text(p).trimAscii()
                        if (addr != "") {
                            args.add("-p")
                            args.add(addr)
                        }
                    }
                }
            case None => ()
        }
        args.add("--dhcp")
        // WireGuard Portal：玩家免装 EasyTier，用现成 WG 客户端入网
        if (HttpUtil.boolean(o, "wgEnabled", false)) {
            let wgCidr = cfgStr(o, "wgCidr", "10.126.14.0/24")
            let wgPort = cfgStr(o, "wgPort", "11013")
            args.add("--vpn-portal")
            args.add("wg://0.0.0.0:${wgPort}/${wgCidr}")
        }
        Docker.forceRemove(ET_CONTAINER)
        let r = Docker.run(args.toArray())
        if (!r.ok()) {
            return Some("启动容器失败: ${r.stderr.trimAscii()}")
        }
        saveConfig(o)
        return None
    }

    public static func stop(): Unit {
        Docker.forceRemove(ET_CONTAINER)
        var o = loadConfig()
        o.put("enabled", JsonBool(false))
        saveConfig(o)
    }

    /* ---------------- 状态查询 ---------------- */

    static func cliOutput(sub: String): String {
        let o = loadConfig()
        let rpcPort = cfgStr(o, "rpcPort", "15890")
        let r = Docker.exec(ET_CONTAINER, ["easytier-cli", "-p", "127.0.0.1:${rpcPort}", sub], node: "local")
        if (!r.ok()) {
            return ""
        }
        return r.stdout.trimAscii()
    }

    /* easytier-cli 输出为 markdown 表格，逐行转 JSON 对象数组 */
    static func parseTable(text: String, fieldNames: Array<String>): JsonArray {
        let arr = JsonArray()
        for (line in text.split("\n")) {
            let l = line.trimAscii()
            if (!l.startsWith("|") || l.contains("----")) {
                continue
            }
            let cells = ArrayList<String>()
            for (seg in l[1..l.size - 1].split("|")) {
                cells.add(seg.trimAscii())
            }
            if (cells.size < fieldNames.size) {
                continue
            }
            if (cells[0] == fieldNames[0]) {
                continue   // 表头行
            }
            let row = JsonObject()
            for (i in 0..fieldNames.size) {
                row.put(fieldNames[i], JsonString(cells[i]))
            }
            arr.add(row)
        }
        return arr
    }

    public static func statusJson(): JsonObject {
        let o = loadConfig()
        let enabled = HttpUtil.boolean(o, "enabled", false)
        let containerUp = Docker.status(ET_CONTAINER) == "running"
        var peers = JsonArray()
        var routes = JsonArray()
        var error = ""
        if (enabled && containerUp) {
            let pj = cliOutput("peer")
            if (pj != "") {
                peers = parseTable(pj, ET_PEER_FIELDS)
            }
            let rj = cliOutput("route")
            if (rj != "") {
                routes = parseTable(rj, ["ipv4", "hostname", "proxy_cidrs", "next_hop_ipv4", "next_hop_hostname", "next_hop_lat", "path_len", "path_latency"])
            }
            if (pj == "" && rj == "") {
                error = "组网核心仍在初始化或 RPC 未就绪，稍后刷新"
            }
        }
        return Jsons.obj([
            ("enabled", JsonBool(enabled)),
            ("running", JsonBool(containerUp)),
            ("config", maskSecret(o)),
            ("peers", peers),
            ("routes", routes),
            ("events", eventsJson()),
            ("traffic", trafficJson()),
            ("error", JsonString(error))
        ])
    }

    /* 密钥打码（operator/viewer 不可见明文） */
    static func maskSecret(o: JsonObject): JsonObject {
        let out = JsonObject()
        for ((k, v) in o.getFields()) {
            if (k == "secret") {
                let s = Jsons.text(v)
                if (s.size > 6) {
                    out.put(k, JsonString(s[..4] + "****" + s[s.size - 2..]))
                } else {
                    out.put(k, JsonString("****"))
                }
            } else {
                out.put(k, v)
            }
        }
        return out
    }

    /* ---------------- 邀请卡 ---------------- */

    /* 本机全部全局 IPv4：hostname -I 优先（多数发行版），Arch 等无此命令时用 ip addr */
    static func localIPv4s(): ArrayList<String> {
        let ips = ArrayList<String>()
        // hostname -I 在 Arch 等发行版不存在（Process 会抛异常），必须兜底
        try {
            let (_, hOut, _) = Process.runOutput("hostname", ["-I"])
            if (hOut.size > 0) {
                for (ip in String.fromUtf8(hOut).trimAscii().split(" ")) {
                    let s = ip.trimAscii()
                    if (s != "" && !s.contains(":")) {
                        ips.add(s)
                    }
                }
            }
        } catch (_: Exception) {
            ()
        }
        if (ips.size == 0) {
            let (_, ipOut2, _) = Process.runOutput("ip", ["-4", "addr", "show", "scope", "global"])
            for (line in String.fromUtf8(ipOut2).split("\n")) {
                let seg = line.trimAscii()
                let inetIdx = idxOf(seg, "inet ")
                if (inetIdx < 0) {
                    continue
                }
                var rest = seg[inetIdx + 5..].trimAscii()
                let sp = idxOf(rest, " ")
                if (sp > 0) {
                    rest = rest[..sp]
                }
                let slash = idxOf(rest, "/")
                if (slash > 0) {
                    rest = rest[..slash]
                }
                if (rest != "" && !rest.contains(":")) {
                    ips.add(rest)
                }
            }
        }
        return ips
    }

    public static func inviteJson(): JsonObject {
        let o = loadConfig()
        let name = cfgStr(o, "networkName", "")
        let secret = cfgStr(o, "secret", "")
        let mode = cfgStr(o, "mode", "join")
        let tcpPort = cfgStr(o, "tcpPort", "11010")
        let addrs = ArrayList<String>()
        if (mode == "host") {
            for (ip in localIPv4s()) {
                addrs.add("tcp://${ip}:${tcpPort}")
            }
        }
        match (o.get("peers")) {
            case Some(v) =>
                if (HttpUtil.kindIs(v, JsonKind.JsArray)) {
                    for (p in v.asArray().getItems()) {
                        let a = Jsons.text(p).trimAscii()
                        if (a != "") {
                            addrs.add(a)
                        }
                    }
                }
            case None => ()
        }
        let arr = JsonArray()
        var sb = StringBuilder()
        var first = true
        for (a in addrs) {
            arr.add(JsonString(a))
            if (!first) {
                sb.append(" -p ")
            }
            sb.append(a)
            first = false
        }
        var cmd = "easytier-core --network-name ${name} --network-secret ${secret}"
        if (addrs.size > 0) {
            cmd = cmd + " -p " + sb.toString()
        }
        return Jsons.obj([
            ("networkName", JsonString(name)),
            ("secret", JsonString(secret)),
            ("addrs", arr),
            ("joinCommand", JsonString(cmd))
        ])
    }

    /* ---------------- 玩家上下线审计 + 流量统计 ---------------- */

    /*
     * 每 30 秒由 Monitor.loop 采样一次 peer 表：
     *   - peer 集合 diff -> 上线/下线事件（独立历史，不混入管理员审计避免刷屏）
     *   - rx/tx 累计计数器的增量 -> 每 peer 累计流量（对端重连计数器回退时按 0 处理）
     * 面板启动/组网恢复后的首轮只建立基线不报事件，防止事件风暴。
     * 持久化：data/et-stats.json
     */
    private static let etMutex = Mutex()
    private static var peerSeen = HashSet<String>()              // 上一轮在线的 peer ipv4
    private static var baselineReady = false
    private static let peerStat = HashMap<String, JsonObject>()  // ipv4 -> 主机名/累计流量/次数
    private static let lastRx = HashMap<String, Float64>()       // 对端上报的累计计数器上次值
    private static let lastTx = HashMap<String, Float64>()
    private static let etEvents = ArrayList<JsonObject>()
    private static let MAX_EVENTS = 200

    static func statsFile(): String {
        return Config.dataRoot + "/et-stats.json"
    }

    static func loadStats(): Unit {
        if (!exists(statsFile())) {
            return
        }
        try {
            let v = JsonValue.fromStr(String.fromUtf8(File.readFrom(statsFile())))
            if (!HttpUtil.kindIs(v, JsonKind.JsObject)) {
                return
            }
            let o = v.asObject()
            etMutex.lock()
            match (o.get("peers")) {
                case Some(ps) =>
                    if (HttpUtil.kindIs(ps, JsonKind.JsObject)) {
                        for ((ip, pv) in ps.asObject().getFields()) {
                            if (HttpUtil.kindIs(pv, JsonKind.JsObject)) {
                                peerStat.add(ip, pv.asObject())
                            }
                        }
                    }
                case None => ()
            }
            match (o.get("events")) {
                case Some(ev) =>
                    if (HttpUtil.kindIs(ev, JsonKind.JsArray)) {
                        for (e in ev.asArray().getItems()) {
                            if (HttpUtil.kindIs(e, JsonKind.JsObject)) {
                                etEvents.add(e.asObject())
                            }
                        }
                    }
                case None => ()
            }
            etMutex.unlock()
            println("[easytier] 已加载组网统计：${peerStat.size} 个节点 ${etEvents.size} 条事件")
        } catch (_: Exception) {
            ()
        }
    }

    static func saveStats(): Unit {
        let root = JsonObject()
        etMutex.lock()
        let peersObj = JsonObject()
        for ((ip, pv) in peerStat) {
            peersObj.put(ip, pv)
        }
        let evArr = JsonArray()
        for (e in etEvents) {
            evArr.add(e)
        }
        etMutex.unlock()
        root.put("peers", peersObj)
        root.put("events", evArr)
        try {
            let tmp = statsFile() + ".tmp"
            File.writeTo(tmp, root.toJsonString().toArray())
            rename(tmp, to: statsFile(), overwrite: true)
        } catch (_: Exception) {
            ()
        }
    }

    /* "4.87 kB" / "0 B" / "1.20 MB" -> KB；无数据（"-" 或空）返回 -1 */
    public static func parseTraffic(s: String): Float64 {
        let t = s.trimAscii()
        if (t == "" || t == "-") {
            return -1.0
        }
        var num = t
        var scale = 1.0
        let lower = t.toAsciiLower()
        if (lower.endsWith("gb")) {
            num = t[..t.size - 2]
            scale = 1024.0 * 1024.0
        } else if (lower.endsWith("mb")) {
            num = t[..t.size - 2]
            scale = 1024.0
        } else if (lower.endsWith("kb")) {
            num = t[..t.size - 2]
        } else if (lower.endsWith("b")) {
            num = t[..t.size - 1]
            scale = 1.0 / 1024.0
        }
        try {
            return Float64.parse(num.trimAscii()) * scale
        } catch (_: Exception) {
            return -1.0
        }
    }

    static func evtTime(): String {
        return DateTime.now().format("MM-dd HH:mm:ss")
    }

    static func addEvent(kind: String, ip: String, host: String): Unit {
        etEvents.add(Jsons.obj([
            ("time", JsonString(evtTime())),
            ("event", JsonString(kind)),
            ("ipv4", JsonString(ip)),
            ("hostname", JsonString(host))
        ]))
        if (etEvents.size > MAX_EVENTS) {
            // 环形上限：删最旧（重建列表避免逐个头部删除）
            let kept = ArrayList<JsonObject>()
            for (i in 1..etEvents.size) {
                kept.add(etEvents[i])
            }
            etEvents.clear()
            for (e in kept) {
                etEvents.add(e)
            }
        }
    }

    /* ipv4 "10.6.6.2/24" -> "10.6.6.2" */
    static func stripMask(ip: String): String {
        let sp = idxOf(ip, "/")
        if (sp > 0) {
            return ip[..sp]
        }
        return ip
    }

    static func f2(v: Float64): JsonFloat {
        let j = JsonFloat(v)
        return j
    }

    public static func sampleOnce(): Unit {
        let o = loadConfig()
        let enabled = HttpUtil.boolean(o, "enabled", false)
        let up = Docker.status(ET_CONTAINER) == "running"
        if (!enabled || !up) {
            etMutex.lock()
            if (!peerSeen.isEmpty()) {
                peerSeen.clear()
            }
            baselineReady = false
            etMutex.unlock()
            return
        }
        let pj = cliOutput("peer")
        if (pj == "") {
            return   // RPC 未就绪，跳过本轮
        }
        let rows = parseTable(pj, ET_PEER_FIELDS)
        // 本轮在线集合（排除本地节点：cost=Local）
        let cur = HashSet<String>()
        let curInfo = HashMap<String, (String, Float64, Float64)>()   // ip -> (hostname, rxKB, txKB)
        for (rowV in rows.getItems()) {
            if (!HttpUtil.kindIs(rowV, JsonKind.JsObject)) {
                continue
            }
            let row = rowV.asObject()
            if (Jsons.text(row.get("cost") ?? JsonString("")) == "Local") {
                continue
            }
            let ip = stripMask(Jsons.text(row.get("ipv4") ?? JsonString("")))
            let host = Jsons.text(row.get("hostname") ?? JsonString(""))
            if (ip == "") {
                continue
            }
            cur.add(ip)
            curInfo.add(ip, (host, parseTraffic(Jsons.text(row.get("rx") ?? JsonString(""))),
                parseTraffic(Jsons.text(row.get("tx") ?? JsonString("")))))
        }
        var notifyEvents = ArrayList<JsonObject>()
        etMutex.lock()
        if (!baselineReady) {
            baselineReady = true
            for (ip in cur) {
                peerSeen.add(ip)
            }
            // 基线轮也记下计数器，避免首轮流量虚增
            for ((ip, info) in curInfo) {
                lastRx.add(ip, info[1])
                lastTx.add(ip, info[2])
            }
            etMutex.unlock()
            return
        }
        // 上线事件
        for (ip in cur) {
            if (!peerSeen.contains(ip)) {
                let host = curInfo.get(ip) ?? ("", -1.0, -1.0)
                addEvent("join", ip, host[0])
                notifyEvents.add(Jsons.obj([
                    ("event", JsonString("peer_join")),
                    ("ipv4", JsonString(ip)),
                    ("hostname", JsonString(host[0])),
                    ("time", JsonString(evtTime()))
                ]))
            }
        }
        // 下线事件
        for (ip in peerSeen) {
            if (!cur.contains(ip)) {
                let host = match (peerStat.get(ip)) {
                    case Some(pv) => Jsons.text(pv.get("hostname") ?? JsonString(""))
                    case None => ""
                }
                addEvent("leave", ip, host)
                notifyEvents.add(Jsons.obj([
                    ("event", JsonString("peer_leave")),
                    ("ipv4", JsonString(ip)),
                    ("hostname", JsonString(host)),
                    ("time", JsonString(evtTime()))
                ]))
            }
        }
        peerSeen.clear()
        for (ip in cur) {
            peerSeen.add(ip)
        }
        // 流量累计（计数器回退按 0 增量处理，仅刷新基线）
        for ((ip, info) in curInfo) {
            let host = info[0]
            let rxNow = info[1]
            let txNow = info[2]
            let pv = match (peerStat.get(ip)) {
                case Some(v) => v
                case None => Jsons.obj([
                    ("hostname", JsonString(host)),
                    ("rxKB", f2(0.0)),
                    ("txKB", f2(0.0)),
                    ("joins", JsonInt(0)),
                    ("firstSeen", JsonString(evtTime()))
                ])
            }
            if (rxNow >= 0.0) {
                let base = lastRx.get(ip) ?? 0.0
                var rxTot = Float64.parse(Jsons.text(pv.get("rxKB") ?? JsonString("0")))
                if (rxNow > base) {
                    rxTot += (rxNow - base)
                }
                pv.put("rxKB", f2(rxTot))
                lastRx.add(ip, rxNow)
            }
            if (txNow >= 0.0) {
                let base = lastTx.get(ip) ?? 0.0
                var txTot = Float64.parse(Jsons.text(pv.get("txKB") ?? JsonString("0")))
                if (txNow > base) {
                    txTot += (txNow - base)
                }
                pv.put("txKB", f2(txTot))
                lastTx.add(ip, txNow)
            }
            // 本轮上线的节点接入次数 +1
            var joinedNow = false
            for (e in notifyEvents) {
                if (Jsons.text(e.get("event") ?? JsonString("")) == "peer_join" &&
                    Jsons.text(e.get("ipv4") ?? JsonString("")) == ip) {
                    joinedNow = true
                    break
                }
            }
            if (joinedNow) {
                pv.put("joins", JsonInt(Int64.parse(Jsons.text(pv.get("joins") ?? JsonString("0"))) + 1))
            }
            pv.put("hostname", JsonString(host))
            pv.put("lastSeen", JsonString(evtTime()))
            peerStat.add(ip, pv)
        }
        etMutex.unlock()
        if (!notifyEvents.isEmpty()) {
            println("[easytier] 节点变动 ${notifyEvents.size} 条")
            for (e in notifyEvents) {
                // 站内通知始终记录（上下线各一条）；webhook 仅在开关开启时推送
                let isJoin = Jsons.text(e.get("event") ?? JsonString("")) == "peer_join"
                let host = Jsons.text(e.get("hostname") ?? JsonString(""))
                let ip = Jsons.text(e.get("ipv4") ?? JsonString(""))
                Notifications.push("mesh", if (isJoin) { "玩家上线：${host}" } else { "节点离线：${host}" }, "虚拟 IP ${ip}")
                if (HttpUtil.boolean(o, "peerNotify", false)) {
                    Monitor.sendWebhook(e)
                }
            }
        }
        saveStats()
    }

    public static func eventsJson(): JsonArray {
        let arr = JsonArray()
        etMutex.lock()
        // 倒序：最新在前
        var i = etEvents.size - 1
        while (i >= 0) {
            arr.add(etEvents[i])
            i -= 1
        }
        etMutex.unlock()
        return arr
    }

    public static func trafficJson(): JsonObject {
        let out = JsonObject()
        etMutex.lock()
        for ((ip, pv) in peerStat) {
            out.put(ip, pv)
        }
        etMutex.unlock()
        return out
    }
}

/* ---------------- REST ---------------- */

public func registerEasyTierRoutes(): Unit {
    router.get("/api/v1/easytier/status", { ctx, _ =>
        if (!Auth.guard(ctx)) {
            return
        }
        HttpUtil.ok(ctx, EasyTier.statusJson())
    })

    router.put("/api/v1/easytier/config", { ctx, _ =>
        if (!Auth.guard(ctx) || !Auth.allowAdmin(ctx)) {
            return
        }
        let body = HttpUtil.bodyJson(ctx)
        var o = body
        o.put("enabled", JsonBool(true))
        match (Auth.current(ctx)) {
            case Some(s) => Users.audit(s.username, "配置并启动 EasyTier 组网(${HttpUtil.str(body, "mode", "join")})")
            case None => ()
        }
        match (EasyTier.apply(o)) {
            case None => HttpUtil.okMsg(ctx, "组网已启动（首次握手可能需要数十秒）")
            case Some(e) => HttpUtil.fail(ctx, 7401, e)
        }
    })

    router.post("/api/v1/easytier/stop", { ctx, _ =>
        if (!Auth.guard(ctx) || !Auth.allowAdmin(ctx)) {
            return
        }
        EasyTier.stop()
        HttpUtil.okMsg(ctx, "组网已停止")
    })

    /* WireGuard 客户端配置（admin；玩家用任意 WG 客户端导入即可入网） */
    router.get("/api/v1/easytier/wg-config", { ctx, _ =>
        if (!Auth.guard(ctx) || !Auth.allowAdmin(ctx)) {
            return
        }
        let o = EasyTier.loadConfig()
        if (!HttpUtil.boolean(o, "wgEnabled", false)) {
            HttpUtil.fail(ctx, 7402, "未启用 WireGuard Portal（在组网配置中勾选）")
            return
        }
        let rpcPort = Jsons.text(o.get("rpcPort") ?? JsonString("15890"))
        let r = Docker.exec(ET_CONTAINER, ["easytier-cli", "-p", "127.0.0.1:${rpcPort}", "vpn-portal"], node: "local")
        if (!r.ok()) {
            HttpUtil.fail(ctx, 7403, "获取 WG 配置失败: ${r.stderr.trimAscii()}")
            return
        }
        // cli 输出的 Endpoint 是占位 0.0.0.0，替换为本机首个全局地址
        var conf = r.stdout.trimAscii()
        let wgPort = Jsons.text(EasyTier.loadConfig().get("wgPort") ?? JsonString("11013"))
        let ips = EasyTier.localIPv4s()
        if (ips.size > 0) {
            conf = conf.replace("0.0.0.0:${wgPort}", "${ips[0]}:${wgPort}")
        }
        HttpUtil.ok(ctx, Jsons.obj([("config", JsonString(conf))]))
    })

    router.get("/api/v1/easytier/invite", { ctx, _ =>
        if (!Auth.guard(ctx) || !Auth.allowAdmin(ctx)) {
            return
        }
        HttpUtil.ok(ctx, EasyTier.inviteJson())
    })
}
