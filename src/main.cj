package gamepanel

/*
 * 游戏方舟 —— 容器化游戏服务器管理面板
 * 入口：初始化数据目录 -> 加载状态 -> 启动计划任务调度线程 -> 启动 HTTP 服务
 */

import stdx.net.http.*
import stdx.encoding.json.*
import stdx.log.*
import std.sync.*
import std.env.*
import std.time.*

public let router = Router()

main() {
    Paths.ensureAll()
    Auth.warmup()
    Store.load()
    println("[gamepanel] 数据目录: ${Config.dataRoot}")
    println("[gamepanel] 监听端口: ${Config.port}")

    registerRoutes()
    Scheduler.start()
    Monitor.start()

    let server = ServerBuilder().addr("0.0.0.0").port(Config.port).distributor(router).build()
    server.logger.level = LogLevel.OFF
    println("[gamepanel] 服务已启动: http://0.0.0.0:${Config.port}")
    server.serve()
}

func getWebRoot(): String {
    match (getVariable("GP_WEB")) {
        case Some(p) => return p
        case None => return getWorkingDirectory().toString() + "/web"
    }
}

func registerRoutes(): Unit {
    /* ---------- 登录（无需鉴权） ---------- */
    router.post("/api/v1/auth/login", { ctx, _ =>
        let body = HttpUtil.bodyJson(ctx)
        let user = HttpUtil.str(body, "username", "")
        let pass = HttpUtil.str(body, "password", "")
        // 限速优先：锁定期间直接拒绝并告知剩余时间
        let lock = Auth.lockRemaining(user)
        if (lock > 0) {
            HttpUtil.fail(ctx, 1002, "失败次数过多已锁定，请 ${lock / 60 + 1} 分钟后再试")
            return
        }
        match (Auth.login(user, pass)) {
            case Some((token, s)) =>
                HttpUtil.ok(ctx, Jsons.obj([
                    ("token", JsonString(token)),
                    ("username", JsonString(s.username)),
                    ("role", JsonString(s.role))
                ]))
            case None =>
                HttpUtil.fail(ctx, 1001, "用户名或密码错误")
        }
    })

    /* 修改自己的密码（所有角色，需旧密码验证） */
    router.post("/api/v1/auth/change-password", { ctx, _ =>
        if (!Auth.guard(ctx)) {
            return
        }
        let body = HttpUtil.bodyJson(ctx)
        let old = HttpUtil.str(body, "oldPassword", "")
        let np = HttpUtil.str(body, "newPassword", "")
        if (old == "" || np == "") {
            HttpUtil.fail(ctx, 1003, "旧密码与新密码不能为空")
            return
        }
        if (np.size < 8) {
            HttpUtil.fail(ctx, 1004, "新密码至少 8 位")
            return
        }
        match (Auth.current(ctx)) {
            case Some(s) =>
                match (Users.verify(s.username, old)) {
                    case Some(_) =>
                        match (Users.upsert(s.username, np, s.role)) {
                            case None =>
                                Users.audit(s.username, "修改了自己的密码")
                                HttpUtil.okMsg(ctx, "密码已修改")
                            case Some(e) => HttpUtil.fail(ctx, 1005, e)
                        }
                    case None => HttpUtil.fail(ctx, 1001, "旧密码不正确")
                }
            case None => HttpUtil.fail(ctx, 1001, "会话失效")
        }
    })

    /* 会话管理（admin）：在线会话列表 + 踢出 */
    router.get("/api/v1/sessions", { ctx, _ =>
        if (!Auth.guard(ctx) || !Auth.allowAdmin(ctx)) {
            return
        }
        let h = ctx.request.headers.getFirst("Authorization") ?? ""
        let selfToken = if (h.startsWith("Bearer ")) { h[7..h.size] } else { "" }
        HttpUtil.ok(ctx, Auth.sessionsJson(selfToken))
    })

    router.delete("/api/v1/sessions/{prefix}", { ctx, md =>
        if (!Auth.guard(ctx) || !Auth.allowAdmin(ctx)) {
            return
        }
        let prefix = md.matchString("prefix")
        match (Auth.current(ctx)) {
            case Some(s) => Users.audit(s.username, "踢出会话 ${prefix}")
            case None => ()
        }
        if (Auth.kickSession(prefix)) {
            HttpUtil.okMsg(ctx, "会话已踢出")
        } else {
            HttpUtil.fail(ctx, 404, "会话不存在或已过期")
        }
    })

    router.post("/api/v1/auth/logout", { ctx, _ =>
        if (!Auth.guard(ctx)) {
            return
        }
        let h = ctx.request.headers.getFirst("Authorization") ?? ""
        if (h.startsWith("Bearer ")) {
            Auth.logout(h[7..h.size])
        }
        HttpUtil.okMsg(ctx, "已退出登录")
    })

    /* ---------- 健康检查 ---------- */
    router.get("/api/v1/health", { ctx, _ =>
        HttpUtil.ok(ctx, Jsons.obj([("status", JsonString("ok"))]))
    })

    registerStaticRoutes(getWebRoot())

    /* 其余业务路由由各模块注册 */
    registerInstanceRoutes()
    registerBackupRoutes()
    registerTaskRoutes()
    registerFileRoutes()
    registerModRoutes()
    registerSystemRoutes()
    registerDiagRoutes()
    registerNotifyRoutes()
    registerMonitorRoutes()
    registerGameCfgRoutes()
    registerImportRoutes()
    registerPlayerRoutes()
    registerUserRoutes()
    registerNodeRoutes()
    registerWsRoutes()
    registerMcVerRoutes()
    registerEasyTierRoutes()
    registerLifecycleRoutes()
}
