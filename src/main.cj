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
