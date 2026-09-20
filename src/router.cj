package gamepanel

/*
 * 正则路由分发器。
 * stdx 默认的 DirectDistributor 只支持精确路径匹配，这里实现自己的分发器：
 *  - 路径用 {name} 声明参数段，例如 /api/v1/instances/{id}/start
 *  - 注册时可绑定 HTTP 方法，方法不匹配返回 405
 *  - 匹配到的捕获组通过 MatchData 传给业务函数
 */

import stdx.net.http.*
import std.regex.*
import std.collection.*

public type RouteFunc = (HttpContext, MatchData) -> Unit

class Route {
    public Route(let pattern: Regex, let method: String, let fn: RouteFunc) {}
}

public class Router <: HttpRequestDistributor {
    private let entries = ArrayList<Route>()

    public init() {}

    /* 注册一条路由。method 传 "*" 表示任意方法。 */
    public func register(path: String, method: String, fn: RouteFunc) {
        entries.add(Route(compile(path), method, fn))
    }

    public func get(path: String, fn: RouteFunc) {
        register(path, "GET", fn)
    }

    public func post(path: String, fn: RouteFunc) {
        register(path, "POST", fn)
    }

    public func put(path: String, fn: RouteFunc) {
        register(path, "PUT", fn)
    }

    public func delete(path: String, fn: RouteFunc) {
        register(path, "DELETE", fn)
    }

    /* HttpRequestDistributor 接口要求的重载：不支持精确注册，仅保持兼容 */
    public func register(path: String, handler: HttpRequestHandler) {
        entries.add(Route(compile(path), "*", { ctx, _ => handler.handle(ctx) }))
    }

    public func distribute(path: String): HttpRequestHandler {
        return FuncHandler({ ctx =>
            let found = dispatch(ctx, path)
            if (!found) {
                notFound(ctx)
            }
        })
    }

    /* 逐条匹配；返回是否命中。方法不匹配记为 405 候选。 */
    private func dispatch(ctx: HttpContext, path: String): Bool {
        let m = ctx.request.method
        var sawPathMatch = false
        for (r in entries) {
            match (r.pattern.find(path, group: true)) {
                case Some(md) =>
                    if (r.method == "*" || r.method == m) {
                        try {
                            r.fn(ctx, md)
                        } catch (e: Exception) {
                            println("[router] 处理 ${path} 异常: ${e.message}")
                            HttpUtil.fail(ctx, 500, "服务器内部错误: ${e.message}")
                        }
                        return true
                    }
                    sawPathMatch = true
                case None => ()
            }
        }
        if (sawPathMatch) {
            HttpUtil.fail(ctx, 405, "HTTP 方法不被允许")
            return true
        }
        return false
    }

    /* /api/v1/instances/{id}/logs -> ^/api/v1/instances/(?<id>[^/]+)/logs$ */
    private func compile(path: String): Regex {
        let sb = StringBuilder()
        sb.append("^")
        for (seg in path.split("/")) {
            if (seg == "") {
                continue
            }
            sb.append("/")
            if (seg.startsWith("{") && seg.endsWith("...}")) {
                // 通配段：匹配剩余全部路径（含 /）
                let name = seg[1..seg.size - 4]
                sb.append("(?<${name}>.+)")
            } else if (seg.startsWith("{") && seg.endsWith("}")) {
                let name = seg[1..seg.size - 1]
                sb.append("(?<${name}>[^/]+)")
            } else {
                sb.append(escape(seg))
            }
        }
        sb.append("/?$")
        return Regex(sb.toString())
    }

    /* 路径段中仅放行 URL 安全字符，其余按字面量转义 */
    private func escape(seg: String): String {
        let sb = StringBuilder()
        for (c in seg.runes()) {
            let ok = (c == r'-') || (c == r'_') || (c == r'.') ||
                (c >= r'0' && c <= r'9') || (c >= r'a' && c <= r'z') || (c >= r'A' && c <= r'Z')
            if (ok) {
                sb.append(c.toString())
            } else {
                sb.append("\\")
                sb.append(c.toString())
            }
        }
        return sb.toString()
    }
}
