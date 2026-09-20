package gamepanel

/*
 * JSON 文件存储：整个面板的状态放在一个 db.json 里。
 * 写入策略：互斥锁串行化 + 先写临时文件再 rename，保证任一时刻文件都是完整 JSON。
 */

import stdx.encoding.json.*
import std.sync.*
import std.fs.*
import std.collection.*

public class Db {
    public var instances = ArrayList<Instance>()
    public var tasks = ArrayList<TaskItem>()
    public var records = ArrayList<BackupRec>()

    public init() {}

    public func findInstance(id: String): ?Instance {
        for (ins in instances) {
            if (ins.id == id) {
                return Some(ins)
            }
        }
        return None
    }

    public func findTask(id: String): ?TaskItem {
        for (t in tasks) {
            if (t.id == id) {
                return Some(t)
            }
        }
        return None
    }

    public func findRecord(id: String): ?BackupRec {
        for (r in records) {
            if (r.id == id) {
                return Some(r)
            }
        }
        return None
    }

    public func toJson(): JsonObject {
        let insArr = JsonArray()
        for (i in instances) {
            insArr.add(i.toJson())
        }
        let taskArr = JsonArray()
        for (t in tasks) {
            taskArr.add(t.toJson())
        }
        let recArr = JsonArray()
        for (r in records) {
            recArr.add(r.toJson())
        }
        return Jsons.obj([
            ("instances", insArr),
            ("tasks", taskArr),
            ("records", recArr)
        ])
    }
}

public class Store {
    private static let mutex = Mutex()
    private static var db = Db()

    /* 供业务代码拿到的视图对象（读多写少场景直接引用，写操作仍走 withLock） */
    public static func data(): Db {
        return db
    }

    public static func load() {
        let path = Paths.dbFile()
        if (!exists(path)) {
            return
        }
        try {
            let text = String.fromUtf8(File.readFrom(path))
            let v = JsonValue.fromStr(text)
            if (!HttpUtil.kindIs(v, JsonKind.JsObject)) {
                return
            }
            let o = v.asObject()
            let loaded = Db()
            match (o.get("instances")) {
                case Some(arr) =>
                    if (HttpUtil.kindIs(arr, JsonKind.JsArray)) {
                        for (item in arr.asArray().getItems()) {
                            if (HttpUtil.kindIs(item, JsonKind.JsObject)) {
                                loaded.instances.add(Instance.fromJson(item.asObject()))
                            }
                        }
                    }
                case None => ()
            }
            match (o.get("tasks")) {
                case Some(arr) =>
                    if (HttpUtil.kindIs(arr, JsonKind.JsArray)) {
                        for (item in arr.asArray().getItems()) {
                            if (HttpUtil.kindIs(item, JsonKind.JsObject)) {
                                loaded.tasks.add(TaskItem.fromJson(item.asObject()))
                            }
                        }
                    }
                case None => ()
            }
            match (o.get("records")) {
                case Some(arr) =>
                    if (HttpUtil.kindIs(arr, JsonKind.JsArray)) {
                        for (item in arr.asArray().getItems()) {
                            if (HttpUtil.kindIs(item, JsonKind.JsObject)) {
                                loaded.records.add(BackupRec.fromJson(item.asObject()))
                            }
                        }
                    }
                case None => ()
            }
            mutex.lock()
            db = loaded
            mutex.unlock()
        } catch (e: Exception) {
            println("[store] db.json 解析失败，按空库启动: ${e.message}")
        }
    }

    /* 任何修改 db 的操作都用 update 包裹，结束时自动落盘 */
    public static func update(fn: (Db) -> Unit) {
        mutex.lock()
        try {
            fn(db)
            persist()
        } finally {
            mutex.unlock()
        }
    }

    private static func persist() {
        let path = Paths.dbFile()
        let tmp = path + ".tmp"
        File.writeTo(tmp, db.toJson().toJsonString().toArray())
        rename(tmp, to: path, overwrite: true)
    }
}
