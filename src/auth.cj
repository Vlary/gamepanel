package gamepanel

/*
 * 会话鉴权：登录签发 Bearer Token，权限按角色三级（viewer/operator/admin）。
 * 级别自动按 HTTP 方法推断（GET=viewer、POST/PUT=operator、DELETE=admin），
 * 业务内更高权限的操作再调 allowAdmin 二次校验。
 * Token 持久化 tokens.json，面板重启不掉登录。
 */

import stdx.net.http.*
import stdx.encoding.json.*
import std.sync.*
import std.time.*
import std.collection.*
import std.fs.*
import std.convert.*
import std.random.*

public class Auth {
    private static let mutex = Mutex()
    // token -> 会话
    private static let tokens = HashMap<String, Session>()

    public static func nowSec(): Int64 {
        return DateTime.now().toUnixTimeStamp().toMilliseconds() / 1000
    }

    public static func warmup(): Unit {
        Users.load()
        loadTokens()
    }

    /* ---------------- 登录与令牌 ---------------- */

    /* 登录成功返回 (token, 会话)，失败返回 None */
    /* 登录失败限速：用户名维度，5 次失败锁 15 分钟（防暴力破解） */
    private static let loginFails = HashMap<String, (Int64, Int64)>()   // name -> (次数, 锁定到)
    private static let MAX_FAILS: Int64 = 5
    private static let LOCK_SECS: Int64 = 900

    /* 返回锁定剩余秒数；0 = 未锁定 */
    public static func lockRemaining(name0: String): Int64 {
        var name = name0
        if (name == "") {
            name = "admin"
        }
        mutex.lock()
        let f = loginFails.get(name)
        mutex.unlock()
        match (f) {
            case Some((_, until)) =>
                let now = nowSec()
                if (until > now) {
                    return until - now
                }
            case None => ()
        }
        return 0
    }

    public static func login(username: String, password: String): ?(String, Session) {
        var name = username
        if (name == "") {
            name = "admin"   // 兼容习惯：不填用户名默认 admin
        }
        let lock = lockRemaining(name)
        if (lock > 0) {
            return None
        }
        match (Users.verify(name, password)) {
            case Some(u) =>
                mutex.lock()
                loginFails.remove(name)
                mutex.unlock()
                let token = randomToken()
                let s = Session()
                s.username = u.username
                s.role = u.role
                s.expire = nowSec() + 7 * 24 * 3600
                mutex.lock()
                tokens.add(token, s)
                mutex.unlock()
                saveTokens()
                Users.audit(u.username, "登录")
                return Some((token, s))
            case None =>
                mutex.lock()
                let (cnt, _) = loginFails.get(name) ?? (0, 0)
                let cnt2 = cnt + 1
                if (cnt2 >= MAX_FAILS) {
                    loginFails.add(name, (0, nowSec() + LOCK_SECS))
                } else {
                    loginFails.add(name, (cnt2, 0))
                }
                mutex.unlock()
                return None
        }
    }

    /* 会话列表（admin）：token 打码，只留前 8 位用于标识与踢出 */
    public static func sessionsJson(selfToken: String): JsonArray {
        let arr = JsonArray()
        mutex.lock()
        for ((token, s) in tokens) {
            arr.add(Jsons.obj([
                ("tokenPrefix", JsonString(token[..8])),
                ("username", JsonString(s.username)),
                ("role", JsonString(s.role)),
                ("expire", JsonInt(s.expire)),
                ("current", JsonBool(token == selfToken))
            ]))
        }
        mutex.unlock()
        return arr
    }

    /* 踢出会话（按前 8 位匹配，避免全 token 暴露在 URL/日志中） */
    public static func kickSession(prefix: String): Bool {
        mutex.lock()
        var hit: ?String = None
        for ((token, _) in tokens) {
            if (token[..8] == prefix) {
                hit = Some(token)
                break
            }
        }
        mutex.unlock()
        match (hit) {
            case Some(t) =>
                logout(t)
                return true
            case None => return false
        }
    }

    public static func logout(token: String) {
        mutex.lock()
        tokens.remove(token)
        mutex.unlock()
        saveTokens()
    }

    /* WS 用：浏览器 WebSocket 无法自定义 header，token 走 query 参数 */
    public static func checkToken(token: String): ?Session {
        return sessionOf(token)
    }

    static func sessionOf(token: String): ?Session {
        mutex.lock()
        let s = tokens.get(token)
        mutex.unlock()
        match (s) {
            case Some(sess) =>
                if (sess.expire >= nowSec()) {
                    return Some(sess)
                }
                mutex.lock()
                tokens.remove(token)
                mutex.unlock()
                return None
            case None => return None
        }
    }

    public static func tokenOfHeader(ctx: HttpContext): String {
        let h = ctx.request.headers.getFirst("Authorization") ?? ""
        if (h.startsWith("Bearer ")) {
            return h[7..h.size]
        }
        return ""
    }

    /* 请求鉴权：登录校验 + 按 HTTP 方法自动定级 */
    public static func guard(ctx: HttpContext): Bool {
        let s = sessionOf(tokenOfHeader(ctx))
        match (s) {
            case Some(sess) =>
                let path = ctx.request.url.path
                // 登录/登出/健康检查不做级别限制
                if (path.contains("/auth/") || path.contains("/health")) {
                    return true
                }
                let need = match (ctx.request.method) {
                    case "GET" => 0
                    case "POST" => 1
                    case "PUT" => 1
                    case _ => 2   // DELETE / 其他
                }
                if (roleLevel(sess.role) >= need) {
                    return true
                }
                HttpUtil.fail(ctx, 403, "权限不足：当前角色 ${sess.role}（${roleName(need)} 及以上可执行此操作）")
                return false
            case None =>
                HttpUtil.fail(ctx, 401, "未登录或登录已过期")
                return false
        }
    }

    /* admin 专属操作二次校验（guard 通过后调用） */
    public static func allowAdmin(ctx: HttpContext): Bool {
        let s = sessionOf(tokenOfHeader(ctx))
        match (s) {
            case Some(sess) =>
                if (sess.role == "admin") {
                    return true
                }
                Users.audit(sess.username, "越权尝试: ${ctx.request.url.path}")
                HttpUtil.fail(ctx, 403, "此操作需要管理员权限")
                return false
            case None =>
                HttpUtil.fail(ctx, 401, "未登录")
                return false
        }
    }

    /* 当前会话（供 handler 记审计） */
    public static func current(ctx: HttpContext): ?Session {
        return sessionOf(tokenOfHeader(ctx))
    }

    static func roleName(level: Int64): String {
        match (level) {
            case 0 => "viewer"
            case 1 => "operator"
            case _ => "admin"
        }
    }

    /* ---------------- token 持久化 ---------------- */

    static func tokensFile(): String {
        return Config.dataRoot + "/tokens.json"
    }

    static func loadTokens(): Unit {
        let path = tokensFile()
        if (!exists(path)) {
            return
        }
        try {
            let v = JsonValue.fromStr(String.fromUtf8(File.readFrom(path)))
            if (!HttpUtil.kindIs(v, JsonKind.JsObject)) {
                return
            }
            let now = nowSec()
            var loaded: Int64 = 0
            for ((tok, item) in v.asObject().getFields()) {
                // 新格式 {user, role, expire}；旧格式（纯数字过期秒）忽略
                if (!HttpUtil.kindIs(item, JsonKind.JsObject)) {
                    continue
                }
                let o = item.asObject()
                let expire = Int64.parse(Jsons.text(o.get("expire") ?? JsonString("0")))
                if (expire >= now) {
                    let s = Session()
                    s.username = Jsons.text(o.get("user") ?? JsonString(""))
                    s.role = Jsons.text(o.get("role") ?? JsonString("viewer"))
                    s.expire = expire
                    tokens.add(tok, s)
                    loaded += 1
                }
            }
            if (loaded > 0) {
                println("[auth] 已恢复 ${loaded} 个登录会话")
            }
        } catch (_: Exception) {
            ()
        }
    }

    static func saveTokens(): Unit {
        let root = JsonObject()
        mutex.lock()
        for ((tok, s) in tokens) {
            root.put(tok, Jsons.obj([
                ("user", JsonString(s.username)),
                ("role", JsonString(s.role)),
                ("expire", JsonInt(s.expire))
            ]))
        }
        mutex.unlock()
        try {
            let tmp = tokensFile() + ".tmp"
            File.writeTo(tmp, root.toJsonString().toArray())
            rename(tmp, to: tokensFile(), overwrite: true)
        } catch (e: Exception) {
            println("[auth] 保存会话失败: ${e.message}")
        }
    }

    private static var tokenSeq: Int64 = 0

    static func randomToken(): String {
        // 种子必须毫秒+序号：按秒会在同秒登录时生成相同 token（曾致会话互相顶掉）
        tokenSeq += 1
        let r = Random(UInt64(Backups.nowMs()) * 1000 + UInt64(tokenSeq))
        let chars = "abcdefghijklmnopqrstuvwxyz0123456789"
        let sb = StringBuilder()
        for (_ in 0..40) {
            let idx = r.nextInt64(chars.size)
            sb.append(chars[idx..idx + 1])
        }
        return sb.toString()
    }
}

/* ---------------- 用户管理 REST（admin） ---------------- */

public func registerUserRoutes(): Unit {
    router.get("/api/v1/users", { ctx, _ =>
        if (!Auth.guard(ctx) || !Auth.allowAdmin(ctx)) {
            return
        }
        HttpUtil.ok(ctx, Jsons.obj([
            ("users", Users.listJson()),
            ("audit", Users.auditJson())
        ]))
    })

    /* body: {username, password, role}——存在则更新角色/密码 */
    router.post("/api/v1/users", { ctx, _ =>
        if (!Auth.guard(ctx) || !Auth.allowAdmin(ctx)) {
            return
        }
        let body = HttpUtil.bodyJson(ctx)
        let username = HttpUtil.str(body, "username", "").trimAscii()
        let password = HttpUtil.str(body, "password", "")
        let role = HttpUtil.str(body, "role", "viewer").trimAscii()
        match (Users.upsert(username, password, role)) {
            case None =>
                match (Auth.current(ctx)) {
                    case Some(s) => Users.audit(s.username, "添加/修改用户 ${username}(${role})")
                    case None => ()
                }
                HttpUtil.okMsg(ctx, "已保存用户 ${username}")
            case Some(e) => HttpUtil.fail(ctx, 7001, e)
        }
    })

    router.delete("/api/v1/users/{name}", { ctx, md =>
        if (!Auth.guard(ctx) || !Auth.allowAdmin(ctx)) {
            return
        }
        let name = md.matchString("name")
        match (Users.remove(name)) {
            case None =>
                match (Auth.current(ctx)) {
                    case Some(s) => Users.audit(s.username, "删除用户 ${name}")
                    case None => ()
                }
                HttpUtil.okMsg(ctx, "已删除 ${name}")
            case Some(e) => HttpUtil.fail(ctx, 7002, e)
        }
    })
}
