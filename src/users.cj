package gamepanel

/*
 * 多用户与角色权限。
 * 三级角色：
 *   viewer   只读（浏览实例/日志/监控/备份列表）
 *   operator 日常运维（启停/配置/备份/文件/Mod/计划任务）
 *   admin    全部权限（删除实例、导入容器、用户与节点管理）
 * 存储：users.json（密码以 salt+sha256 哈希保存，绝不明文落盘）。
 */

import stdx.encoding.json.*
import stdx.crypto.digest.*
import std.fs.*
import std.collection.*
import std.convert.*
import std.random.*
import std.sync.*

/* 用户 */
public class User {
    public var username = ""
    public var passHash = ""   // sha256(salt + password) 十六进制
    public var salt = ""
    public var role = "operator"
    public var createdAt = ""

    public init() {}
}

/* 会话 */
public class Session {
    public var username = ""
    public var role = "viewer"
    public var expire: Int64 = 0

    public init() {}
}

public func roleLevel(role: String): Int64 {
    match (role) {
        case "viewer" => return 0
        case "operator" => return 1
        case "admin" => return 2
        case _ => return 0
    }
}

public class Users {
    private static let list = ArrayList<User>()
    private static let m = Mutex()

    static func lock() { m.lock() }
    static func unlock() { m.unlock() }

    static func file(): String {
        return Config.dataRoot + "/users.json"
    }

    /* 加载；首次（文件不存在）用 GP_ADMIN_PASS 建 admin 账户 */
    public static func load(): Unit {
        lock()
        list.clear()
        unlock()
        if (!exists(file())) {
            let admin = User()
            admin.username = "admin"
            admin.role = "admin"
            admin.salt = genSalt()
            admin.passHash = hashPassword(Config.adminPass, admin.salt)
            admin.createdAt = Instances.nowStr()
            lock()
            list.add(admin)
            unlock()
            save()
            println("[users] 已创建默认管理员账户 admin（密码为 GP_ADMIN_PASS）")
            return
        }
        try {
            let v = JsonValue.fromStr(String.fromUtf8(File.readFrom(file())))
            if (!HttpUtil.kindIs(v, JsonKind.JsArray)) {
                return
            }
            lock()
            for (item in v.asArray().getItems()) {
                if (!HttpUtil.kindIs(item, JsonKind.JsObject)) {
                    continue
                }
                let o = item.asObject()
                let u = User()
                u.username = Jsons.text(o.get("username") ?? JsonString(""))
                u.passHash = Jsons.text(o.get("passHash") ?? JsonString(""))
                u.salt = Jsons.text(o.get("salt") ?? JsonString(""))
                u.role = Jsons.text(o.get("role") ?? JsonString("viewer"))
                u.createdAt = Jsons.text(o.get("createdAt") ?? JsonString(""))
                if (u.username != "" && u.passHash != "") {
                    list.add(u)
                }
            }
            unlock()
        } catch (_: Exception) {
            ()
        }
    }

    public static func save(): Unit {
        lock()
        let arr = JsonArray()
        for (u in list) {
            arr.add(Jsons.obj([
                ("username", JsonString(u.username)),
                ("passHash", JsonString(u.passHash)),
                ("salt", JsonString(u.salt)),
                ("role", JsonString(u.role)),
                ("createdAt", JsonString(u.createdAt))
            ]))
        }
        unlock()
        try {
            let tmp = file() + ".tmp"
            File.writeTo(tmp, arr.toJsonString().toArray())
            rename(tmp, to: file(), overwrite: true)
        } catch (e: Exception) {
            println("[users] 保存失败: ${e.message}")
        }
    }

    public static func verify(username: String, password: String): ?User {
        lock()
        var found: ?User = None
        for (u in list) {
            if (u.username == username) {
                found = Some(u)
                break
            }
        }
        unlock()
        match (found) {
            case Some(u) =>
                if (hashPassword(password, u.salt) == u.passHash) {
                    return Some(u)
                }
                return None
            case None => return None
        }
    }

    /* 添加/更新用户；返回错误说明 */
    public static func upsert(username: String, password: String, role: String): ?String {
        if (username == "" || password == "") {
            return Some("用户名与密码不能为空")
        }
        if (roleLevel(role) == 0 && role != "viewer") {
            return Some("角色必须是 viewer / operator / admin")
        }
        lock()
        for (u in list) {
            if (u.username == username) {
                u.role = role
                if (password != "") {
                    u.salt = genSalt()
                    u.passHash = hashPassword(password, u.salt)
                }
                unlock()
                save()
                return None
            }
        }
        let u = User()
        u.username = username
        u.role = role
        u.salt = genSalt()
        u.passHash = hashPassword(password, u.salt)
        u.createdAt = Instances.nowStr()
        list.add(u)
        unlock()
        save()
        return None
    }

    public static func remove(username: String): ?String {
        if (username == "admin") {
            return Some("内置 admin 账户不可删除")
        }
        lock()
        let keep = ArrayList<User>()
        var found = false
        for (u in list) {
            if (u.username == username) {
                found = true
            } else {
                keep.add(u)
            }
        }
        if (found) {
            list.clear()
            for (u in keep) {
                list.add(u)
            }
            unlock()
            save()
            return None
        }
        unlock()
        return Some("用户不存在")
    }

    public static func listJson(): JsonArray {
        let arr = JsonArray()
        lock()
        for (u in list) {
            arr.add(Jsons.obj([
                ("username", JsonString(u.username)),
                ("role", JsonString(u.role)),
                ("createdAt", JsonString(u.createdAt))
            ]))
        }
        unlock()
        return arr
    }

    /* 审计日志：谁在什么时候做了什么（环形 200 条，audit.json） */
    public static func audit(username: String, action: String): Unit {
        let path = Config.dataRoot + "/audit.json"
        var entries = ArrayList<JsonObject>()
        try {
            if (exists(path)) {
                let v = JsonValue.fromStr(String.fromUtf8(File.readFrom(path)))
                if (HttpUtil.kindIs(v, JsonKind.JsArray)) {
                    for (item in v.asArray().getItems()) {
                        if (HttpUtil.kindIs(item, JsonKind.JsObject)) {
                            entries.add(item.asObject())
                        }
                    }
                }
            }
        } catch (_: Exception) {
            ()
        }
        entries.add(Jsons.obj([
            ("user", JsonString(username)),
            ("action", JsonString(action)),
            ("time", JsonString(Instances.nowStr()))
        ]))
        while (entries.size > 200) {
            let keep = ArrayList<JsonObject>()
            for (i in 1..entries.size) {
                keep.add(entries[i])
            }
            entries.clear()
            for (e in keep) {
                entries.add(e)
            }
        }
        let arr = JsonArray()
        for (e in entries) {
            arr.add(e)
        }
        try {
            File.writeTo(path, arr.toJsonString().toArray())
        } catch (_: Exception) {
            ()
        }
    }

    public static func auditJson(): JsonArray {
        let path = Config.dataRoot + "/audit.json"
        let arr = JsonArray()
        if (!exists(path)) {
            return arr
        }
        try {
            let v = JsonValue.fromStr(String.fromUtf8(File.readFrom(path)))
            if (HttpUtil.kindIs(v, JsonKind.JsArray)) {
                for (item in v.asArray().getItems()) {
                    arr.add(item)
                }
            }
        } catch (_: Exception) {
            ()
        }
        return arr
    }

    public static func hashPassword(password: String, salt: String): String {
        // SHA256 流式接口：write -> finish
        let h = SHA256()
        h.write((salt + password).toArray())
        let d = h.finish()
        let sb = StringBuilder()
        let hex = "0123456789abcdef"
        for (b in d) {
            let hi = Int64(b) / 16
            let lo = Int64(b) % 16
            sb.append(hex[hi..hi + 1])
            sb.append(hex[lo..lo + 1])
        }
        return sb.toString()
    }

    static func genSalt(): String {
        let r = Random(UInt64(Backups.nowMs()))
        let chars = "abcdefghijklmnopqrstuvwxyz0123456789"
        let sb = StringBuilder()
        for (_ in 0..16) {
            let idx = r.nextInt64(chars.size)
            sb.append(chars[idx..idx + 1])
        }
        return sb.toString()
    }
}
