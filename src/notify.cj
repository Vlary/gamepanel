package gamepanel

/*
 * 站内通知中心：实例异常退出 / 计划任务失败 / 玩家上下线（开启推送时）等事件
 * 落 data/notifications.json（环形 100 条，面板重启不丢）。
 * 已读状态为全局（面向小团队运维场景，admin 处理即已读）。
 */

import stdx.net.http.*
import stdx.encoding.json.*
import std.sync.*
import std.fs.*
import std.collection.*

public class Notifications {
    private static let mutex = Mutex()
    private static let items = ArrayList<JsonObject>()
    private static let MAX = 100
    private static var loaded = false

    static func file(): String {
        return Config.dataRoot + "/notifications.json"
    }

    static func ensureLoaded(): Unit {
        if (loaded) {
            return
        }
        loaded = true
        if (!exists(file())) {
            return
        }
        try {
            let v = JsonValue.fromStr(String.fromUtf8(File.readFrom(file())))
            if (HttpUtil.kindIs(v, JsonKind.JsArray)) {
                for (e in v.asArray().getItems()) {
                    if (HttpUtil.kindIs(e, JsonKind.JsObject)) {
                        items.add(e.asObject())
                    }
                }
            }
            println("[notify] 已加载 ${items.size} 条通知")
        } catch (_: Exception) {
            ()
        }
    }

    static func save(): Unit {
        let arr = JsonArray()
        mutex.lock()
        for (e in items) {
            arr.add(e)
        }
        mutex.unlock()
        try {
            let tmp = file() + ".tmp"
            File.writeTo(tmp, arr.toJsonString().toArray())
            rename(tmp, to: file(), overwrite: true)
        } catch (_: Exception) {
            ()
        }
    }

    /* kind: instance | task | mesh；新通知未读 */
    public static func push(kind: String, title: String, body: String): Unit {
        ensureLoaded()
        mutex.lock()
        items.add(Jsons.obj([
            ("id", JsonString("n-${Backups.genRecId()}")),
            ("time", JsonString(Instances.nowStr())),
            ("kind", JsonString(kind)),
            ("title", JsonString(title)),
            ("body", JsonString(body)),
            ("read", JsonBool(false))
        ]))
        if (items.size > MAX) {
            let keep = ArrayList<JsonObject>()
            for (i in 1..items.size) {
                keep.add(items[i])
            }
            items.clear()
            for (e in keep) {
                items.add(e)
            }
        }
        mutex.unlock()
        save()
    }

    public static func listJson(): JsonArray {
        ensureLoaded()
        let arr = JsonArray()
        mutex.lock()
        var i = items.size - 1
        while (i >= 0) {
            arr.add(items[i])
            i -= 1
        }
        mutex.unlock()
        return arr
    }

    public static func unreadCount(): Int64 {
        ensureLoaded()
        var n: Int64 = 0
        mutex.lock()
        for (e in items) {
            if (!HttpUtil.boolean(e, "read", false)) {
                n += 1
            }
        }
        mutex.unlock()
        return n
    }

    public static func markAllRead(): Unit {
        ensureLoaded()
        mutex.lock()
        for (e in items) {
            e.put("read", JsonBool(true))
        }
        mutex.unlock()
        save()
    }

    public static func clear(): Unit {
        mutex.lock()
        items.clear()
        mutex.unlock()
        save()
    }
}

public func registerNotifyRoutes(): Unit {
    router.get("/api/v1/notifications", { ctx, _ =>
        if (!Auth.guard(ctx)) {
            return
        }
        HttpUtil.ok(ctx, Jsons.obj([
            ("unread", JsonInt(Notifications.unreadCount())),
            ("items", Notifications.listJson())
        ]))
    })

    router.post("/api/v1/notifications/read-all", { ctx, _ =>
        if (!Auth.guard(ctx)) {
            return
        }
        Notifications.markAllRead()
        HttpUtil.okMsg(ctx, "已全部标记已读")
    })

    router.post("/api/v1/notifications/clear", { ctx, _ =>
        if (!Auth.guard(ctx)) {
            return
        }
        Notifications.clear()
        HttpUtil.okMsg(ctx, "通知已清空")
    })
}
