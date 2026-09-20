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
import std.fs.*
import std.collection.*
import std.convert.*
import std.process.*

let ET_CONTAINER = "gp-easytier"
let ET_IMAGE = "easytier/easytier:latest"

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
                peers = parseTable(pj, ["ipv4", "hostname", "cost", "latency_ms", "loss", "rx", "tx", "tunnel_proto", "nat_type", "version"])
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
