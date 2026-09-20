package gamepanel

/*
 * 资源监控与异常检测线程。
 * 每 30 秒对全部实例采样一次：
 *   1. CPU% / 内存占用写入内存环形历史（默认保留 120 点 = 1 小时），供 /metrics 接口画曲线
 *   2. 检测"运行中 -> 已退出"的状态变化；非用户主动停止的退出视为意外崩溃，
 *      若配置了 GP_NOTIFY_URL 则发送 Webhook 通知（POST JSON）
 */

import stdx.net.http.*
import stdx.net.tls.*
import stdx.encoding.json.*
import std.sync.*
import std.time.*
import std.collection.*
import std.env.*
import std.process.*
import std.fs.*
import std.convert.*

/* 一次采样点 */
public class Sample {
    public var t = ""        // HH:mm
    public var cpu: Float64 = 0.0   // 百分比
    public var memMB: Float64 = 0.0
    public init() {}
}

/* 定长环形缓冲：写满覆盖最旧，避免 ArrayList 头部删除的语义歧义 */
class Ring {
    private let buf: Array<Sample>
    private var head = 0
    private var count = 0

    public init(capacity: Int64) {
        buf = Array<Sample>(capacity, repeat: Sample())
    }

    public func push(s: Sample) {
        buf[head] = s
        head = (head + 1) % buf.size
        if (count < buf.size) {
            count += 1
        }
    }

    public func all(): ArrayList<Sample> {
        let out = ArrayList<Sample>()
        let cap = buf.size
        var start = (head - count + cap) % cap
        for (_ in 0..count) {
            out.add(buf[start])
            start = (start + 1) % cap
        }
        return out
    }
}

public class Monitor {
    private static let mutex = Mutex()
    private static let history = HashMap<String, Ring>()
    // 最新一次资源占用（供列表接口直读，避免 docker stats 阻塞 1~2 秒）
    private static let latest = HashMap<String, (String, String)>()
    // 数据目录占用缓存（du 遍历慢，60 秒刷新一次）
    private static var dataUsedKB: Int64 = -1
    private static var dirCheckTick: Int64 = 0
    private static let lastStatus = HashMap<String, String>()
    // 用户主动操作（停止/重启/删除）时间戳，用于区分意外退出
    private static let userActionAt = HashMap<String, Int64>()
    private static let MAX_POINTS = 120
    private static var notifyUrl = ""

    static init() {
        notifyUrl = getVariable("GP_NOTIFY_URL") ?? ""
    }

    public static func start() {
        loadHistory()
        EasyTier.loadStats()
        spawn {
            loop()
        }
    }

    /* 历史持久化：重启面板不丢曲线 */
    static func metricsFile(): String {
        return Config.dataRoot + "/metrics.json"
    }

    static func loadHistory(): Unit {
        let path = metricsFile()
        if (!exists(path)) {
            return
        }
        try {
            let v = JsonValue.fromStr(String.fromUtf8(File.readFrom(path)))
            if (!HttpUtil.kindIs(v, JsonKind.JsObject)) {
                return
            }
            mutex.lock()
            for ((id, arr) in v.asObject().getFields()) {
                if (!HttpUtil.kindIs(arr, JsonKind.JsArray)) {
                    continue
                }
                let ring = Ring(MAX_POINTS)
                for (item in arr.asArray().getItems()) {
                    if (!HttpUtil.kindIs(item, JsonKind.JsObject)) {
                        continue
                    }
                    let o = item.asObject()
                    let s = Sample()
                    s.t = Jsons.text(o.get("t") ?? JsonString(""))
                    s.cpu = Float64.parse(Jsons.text(o.get("cpu") ?? JsonString("0")))
                    s.memMB = Float64.parse(Jsons.text(o.get("memMB") ?? JsonString("0")))
                    ring.push(s)
                }
                history.add(id, ring)
            }
            mutex.unlock()
            println("[monitor] 已加载 ${history.size} 个实例的历史监控")
        } catch (_: Exception) {
            ()
        }
    }

    static func saveHistory(): Unit {
        let root = JsonObject()
        mutex.lock()
        for ((id, ring) in history) {
            let arr = JsonArray()
            for (s in ring.all()) {
                arr.add(Jsons.obj([
                    ("t", JsonString(s.t)),
                    ("cpu", JsonFloat(s.cpu)),
                    ("memMB", JsonFloat(s.memMB))
                ]))
            }
            root.put(id, arr)
        }
        mutex.unlock()
        try {
            let tmp = metricsFile() + ".tmp"
            File.writeTo(tmp, root.toJsonString().toArray())
            rename(tmp, to: metricsFile(), overwrite: true)
        } catch (_: Exception) {
            ()
        }
    }

    static func loop(): Unit {
        while (true) {
            sleep(30 * Duration.second)
            dirCheckTick += 1
            if (dirCheckTick % 2 == 1 || dataUsedKB < 0) {
                dataUsedKB = dirSizeKBCached()
            }
            if (dirCheckTick % 2 == 0) {
                saveHistory()
            }
            for (ins in Store.data().instances) {
                let st = Docker.status(ins.containerName(), node: ins.node)
                trackStatus(ins, st)
                if (st == "running") {
                    takeSample(ins)
                } else {
                    mutex.lock()
                    latest.remove(ins.id)
                    mutex.unlock()
                }
            }
            // 组网 peer 采样：上下线事件 + 流量累计（内部自判启用状态，未启用时零开销）
            EasyTier.sampleOnce()
        }
    }

    static func dirSizeKBCached(): Int64 {
        let (code, out, _) = Process.runOutput("du", ["-sk", Config.dataRoot])
        if (code != 0) {
            return 0
        }
        let parts = String.fromUtf8(out).split("\t")
        try {
            return Int64.parse(parts[0])
        } catch (_: Exception) {
            return 0
        }
    }

    /* 状态变化检测 + 意外退出通知 */
    static func trackStatus(ins: Instance, st: String): Unit {
        let prev = lastStatus.get(ins.id) ?? ""
        if (prev != st) {
            lastStatus.add(ins.id, st)
            if (prev == "running" && (st == "exited" || st == "missing")) {
                let act = userActionAt.get(ins.id) ?? 0
                let now = Backups.nowMs() / 1000
                if (now - act > 90) {
                    // 排除刚发生的用户操作 -> 判定为意外退出
                    println("[monitor] 实例 ${ins.name}(${ins.id}) 意外退出（${st}）")
                    notify(ins, st)
                }
            }
        }
    }

    static func notify(ins: Instance, st: String): Unit {
        sendWebhook(Jsons.obj([
            ("event", JsonString("instance_exit")),
            ("instance", JsonString(ins.name)),
            ("id", JsonString(ins.id)),
            ("game", JsonString(ins.game)),
            ("status", JsonString(st)),
            ("time", JsonString(Instances.nowStr()))
        ]))
    }

    /* 通用 Webhook：GP_NOTIFY_URL POST JSON（实例异常退出 / 组网玩家上下线共用） */
    public static func sendWebhook(payload: JsonObject): Unit {
        if (notifyUrl == "") {
            return
        }
        spawn {
            try {
                var rest0 = notifyUrl
                if (notifyUrl.startsWith("https://")) {
                    rest0 = notifyUrl[8..]
                } else if (notifyUrl.startsWith("http://")) {
                    rest0 = notifyUrl[7..]
                }
                var host = rest0
                let slash = idxOf(rest0, "/")
                if (slash > 0) {
                    host = rest0[..slash]
                }
                var cfg = TlsClientConfig()
                cfg.serverName = Some(host)
                let client = ClientBuilder().readTimeout(10 * Duration.second).tlsConfig(cfg).build()
                let req = HttpRequestBuilder().url(notifyUrl).post()
                    .header("content-type", "application/json")
                    .header("accept-encoding", "identity")
                    .body(payload.toJsonString()).build()
                let resp = client.send(req)
                println("[monitor] Webhook 已发送: ${Int64(resp.status)}")
                client.close()
            } catch (e: Exception) {
                println("[monitor] Webhook 发送失败: ${e.message}")
            }
        }
    }

    /* 用户主动停止/重启/删除前调用，避免误报 */
    public static func markUserAction(id: String) {
        userActionAt.add(id, Backups.nowMs() / 1000)
    }

    static func takeSample(ins: Instance): Unit {
        let (cpuS, memS) = Docker.stats(ins.containerName(), node: ins.node)
        mutex.lock()
        latest.add(ins.id, (cpuS, memS))
        mutex.unlock()
        let s = Sample()
        s.t = DateTime.now().format("HH:mm")
        s.cpu = parseCpu(cpuS)
        s.memMB = parseMem(memS)
        mutex.lock()
        match (history.get(ins.id)) {
            case Some(ring) =>
                ring.push(s)
            case None =>
                let ring = Ring(MAX_POINTS)
                ring.push(s)
                history.add(ins.id, ring)
        }
        mutex.unlock()
    }

    /* "57.94%" -> 57.94 */
    static func parseCpu(s: String): Float64 {
        if (s == "") {
            return 0.0
        }
        var v = s
        if (v.endsWith("%")) {
            v = v[..v.size - 1]
        }
        try {
            return Float64.parse(v)
        } catch (_: Exception) {
            return 0.0
        }
    }

    /* "140.7MiB / 1GiB" -> 140.7（MB） */
    static func parseMem(s: String): Float64 {
        if (s == "") {
            return 0.0
        }
        var used = s
        let slash = idxOf(s, "/")
        if (slash > 0) {
            used = s[..slash].trimAscii()
        }
        try {
            if (used.endsWith("GiB")) {
                return Float64.parse(used[..used.size - 3].trimAscii()) * 1024.0
            }
            if (used.endsWith("MiB")) {
                return Float64.parse(used[..used.size - 3].trimAscii())
            }
            if (used.endsWith("KiB")) {
                return Float64.parse(used[..used.size - 3].trimAscii()) / 1024.0
            }
            if (used.endsWith("B")) {
                return Float64.parse(used[..used.size - 1].trimAscii()) / (1024.0 * 1024.0)
            }
        } catch (_: Exception) {
            return 0.0
        }
        return 0.0
    }

    /* 列表/详情接口直读缓存，避免同步等待 docker stats */
    public static func latestStats(id: String): (String, String) {
        mutex.lock()
        let v = latest.get(id)
        mutex.unlock()
        match (v) {
            case Some(pair) => return pair
            case None => return ("", "")
        }
    }

    public static func dataUsedKBNow(): Int64 {
        if (dataUsedKB < 0) {
            dataUsedKB = dirSizeKBCached()
        }
        return dataUsedKB
    }

    public static func metricsJson(id: String): JsonArray {
        let arr = JsonArray()
        mutex.lock()
        let list = history.get(id)
        mutex.unlock()
        match (list) {
            case Some(ring) =>
                for (s in ring.all()) {
                    arr.add(Jsons.obj([
                        ("t", JsonString(s.t)),
                        ("cpu", JsonFloat(s.cpu)),
                        ("memMB", JsonFloat(s.memMB))
                    ]))
                }
            case None => ()
        }
        return arr
    }

    /* 实例删除时清理内存记录 */
    public static func cleanup(id: String) {
        mutex.lock()
        history.remove(id)
        lastStatus.remove(id)
        userActionAt.remove(id)
        latest.remove(id)
        mutex.unlock()
    }
}

/* 监控相关 REST 路由 */
public func registerMonitorRoutes(): Unit {
    router.get("/api/v1/instances/{id}/metrics", { ctx, md =>
        if (!Auth.guard(ctx)) {
            return
        }
        match (Instances.findOr404(ctx, md.matchString("id"))) {
            case Some(ins) => HttpUtil.ok(ctx, Monitor.metricsJson(ins.id))
            case None => ()
        }
    })
}
