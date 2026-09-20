package gamepanel

/*
 * 实例操作状态机：耗时操作（优雅关服/打包备份/解压恢复）异步执行，
 * 接口立即返回，前端通过列表里的 operation 字段展示"停止中…"并轮询刷新。
 */

import std.sync.*
import std.collection.*

public class Ops {
    private static let mutex = Mutex()
    // instanceId -> 操作名（stopping/restarting/backing-up/snapshotting/restoring）
    private static let ops = HashMap<String, String>()

    public static func set(id: String, op: String) {
        mutex.lock()
        ops.add(id, op)
        mutex.unlock()
    }

    public static func clear(id: String) {
        mutex.lock()
        ops.remove(id)
        mutex.unlock()
    }

    public static func get(id: String): String {
        mutex.lock()
        let v = ops.get(id)
        mutex.unlock()
        return v ?? ""
    }

    /* 后台执行一个耗时操作：标记 -> 执行 -> 清除（失败写日志） */
    public static func runAsync(id: String, op: String, fn: () -> ?String): Unit {
        set(id, op)
        spawn {
            let err = fn()
            match (err) {
                case Some(e) => println("[ops] ${id} ${op} 失败: ${e}")
                case None => ()
            }
            clear(id)
        }
    }
}
