package gamepanel

/*
 * HTTP 与 JSON 工具集：统一响应格式、请求体解析、构造辅助。
 * 面板所有接口返回 {code:0, data:...} 或 {code:>0, msg:"..."}，前端据此分支。
 */

import stdx.net.http.*
import stdx.encoding.json.*
import std.collection.*

/* JSON 构造辅助：把冗长的 JsonObject().put(...) 压缩成一行 */
public class Jsons {
    public static func obj(pairs: Array<(String, JsonValue)>): JsonObject {
        let o = JsonObject()
        for ((k, v) in pairs) {
            o.put(k, v)
        }
        return o
    }

    public static func arr(items: Array<JsonValue>): JsonArray {
        return JsonArray(ArrayList<JsonValue>(items))
    }

    public static func s(v: String): JsonValue {
        return JsonString(v)
    }

    public static func i(v: Int64): JsonValue {
        return JsonInt(v)
    }

    public static func b(v: Bool): JsonValue {
        return JsonBool(v)
    }

    public static func f(v: Float64): JsonValue {
        return JsonFloat(v)
    }

    /* 取 JSON 值的纯文本：字符串取原值，其余取紧凑表示 */
    public static func text(v: JsonValue): String {
        if (HttpUtil.kindIs(v, JsonKind.JsString)) {
            return v.asString().getValue()
        }
        return v.toString()
    }
}

public class HttpUtil {
    /* 读出请求体全部字节并按 UTF-8 转字符串 */
    public static func readBody(ctx: HttpContext): String {
        let stream = ctx.request.body
        let chunks = ArrayList<Array<Byte>>()
        var total = 0
        while (true) {
            let buf = Array<Byte>(4096, repeat: 0)
            let n = stream.read(buf)
            if (n <= 0) {
                break
            }
            total += n
            chunks.add(buf[..n])
        }
        let all = Array<Byte>(total, repeat: 0)
        var pos = 0
        for (c in chunks) {
            for (i in 0..c.size) {
                all[pos] = c[i]
                pos += 1
            }
        }
        return String.fromUtf8(all)
    }

    /* 把请求体解析为 JsonObject，解析失败抛出异常由路由层兜底 */
    public static func bodyJson(ctx: HttpContext): JsonObject {
        let text = readBody(ctx)
        let v = JsonValue.fromStr(text)
        if (!HttpUtil.kindIs(v, JsonKind.JsObject)) {
            throw Exception("请求体必须是 JSON 对象")
        }
        return v.asObject()
    }

    /* 取 JSON 字段的可选字符串/整数，缺省给默认值 */
    public static func str(o: JsonObject, key: String, def: String): String {
        match (o.get(key)) {
            case Some(v) => return Jsons.text(v)
            case None => return def
        }
    }

    public static func int(o: JsonObject, key: String, def: Int64): Int64 {
        match (o.get(key)) {
            case Some(v) =>
                if (HttpUtil.kindIs(v, JsonKind.JsInt)) {
                    return v.asInt().getValue()
                }
                return def
            case None => return def
        }
    }

    public static func boolean(o: JsonObject, key: String, def: Bool): Bool {
        match (o.get(key)) {
            case Some(v) =>
                if (HttpUtil.kindIs(v, JsonKind.JsBool)) {
                    return v.asBool().getValue()
                }
                return def
            case None => return def
        }
    }

    /* 仓颉枚举不支持 ==，统一走 match 判断 */
    public static func kindIs(v: JsonValue, k: JsonKind): Bool {
        match ((v.kind(), k)) {
            case (JsonKind.JsNull, JsonKind.JsNull) => true
            case (JsonKind.JsBool, JsonKind.JsBool) => true
            case (JsonKind.JsInt, JsonKind.JsInt) => true
            case (JsonKind.JsFloat, JsonKind.JsFloat) => true
            case (JsonKind.JsString, JsonKind.JsString) => true
            case (JsonKind.JsArray, JsonKind.JsArray) => true
            case (JsonKind.JsObject, JsonKind.JsObject) => true
            case _ => false
        }
    }

    public static func raw(ctx: HttpContext, status: UInt16, contentType: String, body: String) {
        ctx.responseBuilder.status(status).header("Content-Type", contentType).body(body)
    }

    public static func rawBytes(ctx: HttpContext, status: UInt16, contentType: String, body: Array<Byte>) {
        ctx.responseBuilder.status(status).header("Content-Type", contentType).body(body)
    }

    public static func ok(ctx: HttpContext, data: JsonValue) {
        json(ctx, 200, Jsons.obj([("code", JsonInt(0)), ("data", data)]))
    }

    public static func okMsg(ctx: HttpContext, msg: String) {
        json(ctx, 200, Jsons.obj([("code", JsonInt(0)), ("msg", JsonString(msg))]))
    }

    public static func fail(ctx: HttpContext, code: Int64, msg: String) {
        json(ctx, 200, Jsons.obj([("code", JsonInt(code)), ("msg", JsonString(msg))]))
    }

    public static func json(ctx: HttpContext, status: UInt16, v: JsonValue) {
        ctx.responseBuilder.status(status).header("Content-Type", "application/json; charset=utf-8").body(v.toJsonString())
    }
}
