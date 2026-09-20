package gamepanel

/*
 * 玩家管理（当前支持 Minecraft，其余游戏返回未支持）。
 * 列表读取服务器数据目录里的 whitelist.json / ops.json / banned-players.json；
 * 增删操作通过 RCON 命令让服务器自己维护（权威数据源永远是服务器侧）。
 */

import stdx.net.http.*
import stdx.encoding.json.*
import std.fs.*
import std.collection.*

public class Players {
    /* 读一个玩家 JSON 文件（name + uuid 列表），文件不存在/非法返回空 */
    static func loadList(dataDir: String, file: String): JsonArray {
        let abs = dataDir + "/" + file
        if (!exists(abs)) {
            return JsonArray()
        }
        try {
            let v = JsonValue.fromStr(String.fromUtf8(File.readFrom(abs)))
            if (HttpUtil.kindIs(v, JsonKind.JsArray)) {
                return v.asArray()
            }
        } catch (_: Exception) {
            ()
        }
        return JsonArray()
    }

    /* 摘要：name / uuid（有 bannedTo 给出解封时间） */
    static func briefList(dataDir: String, file: String): JsonArray {
        let out = JsonArray()
        for (item in loadList(dataDir, file).getItems()) {
            if (!HttpUtil.kindIs(item, JsonKind.JsObject)) {
                continue
            }
            let o = item.asObject()
            out.add(Jsons.obj([
                ("name", JsonString(Jsons.text(o.get("name") ?? JsonString("")))),
                ("uuid", JsonString(Jsons.text(o.get("uuid") ?? JsonString(""))))
            ]))
        }
        return out
    }

    /* 在线玩家：RCON list 命令输出 "There are 2 of a max of 20 players online: a, b" */
    static func onlinePlayers(ins: Instance): Array<String> {
        if (Docker.status(ins.containerName()) != "running") {
            return []
        }
        let r = Docker.exec(ins.containerName(), ["rcon-cli", "--host", "127.0.0.1", "list"])
        if (!r.ok()) {
            return []
        }
        let out = r.stdout.trimAscii()
        let idx = idxOf(out, ":")
        if (idx < 0) {
            return []
        }
        let names = out[idx + 1..].trimAscii()
        if (names == "") {
            return []
        }
        return names.split(", ")
    }

    /* 动作 -> docker exec rcon-cli 命令映射（rcon-cli 是 itzg 镜像内置的 RCON 客户端） */
    static func rconFor(action: String, player: String): ?Array<String> {
        match (action) {
            case "whitelist-add" => return Some(["rcon-cli", "--host", "127.0.0.1", "whitelist", "add", player])
            case "whitelist-remove" => return Some(["rcon-cli", "--host", "127.0.0.1", "whitelist", "remove", player])
            case "op" => return Some(["rcon-cli", "--host", "127.0.0.1", "op", player])
            case "deop" => return Some(["rcon-cli", "--host", "127.0.0.1", "deop", player])
            case "ban" => return Some(["rcon-cli", "--host", "127.0.0.1", "ban", player])
            case "pardon" => return Some(["rcon-cli", "--host", "127.0.0.1", "pardon", player])
            case "kick" => return Some(["rcon-cli", "--host", "127.0.0.1", "kick", player])
            case _ => return None
        }
    }
}

/* ---------------- REST 路由 ---------------- */

public func registerPlayerRoutes(): Unit {
    router.get("/api/v1/instances/{id}/players", { ctx, md =>
        if (!Auth.guard(ctx)) {
            return
        }
        match (Instances.findOr404(ctx, md.matchString("id"))) {
            case Some(ins) =>
                if (ins.game != "minecraft") {
                    HttpUtil.fail(ctx, 6100, "玩家管理当前仅支持 Minecraft（其他游戏请用控制台命令或文件管理）")
                    return
                }
                let online = JsonArray()
                for (n in Players.onlinePlayers(ins)) {
                    online.add(JsonString(n))
                }
                HttpUtil.ok(ctx, Jsons.obj([
                    ("online", online),
                    ("whitelist", Players.briefList(ins.dataDir, "whitelist.json")),
                    ("ops", Players.briefList(ins.dataDir, "ops.json")),
                    ("banned", Players.briefList(ins.dataDir, "banned-players.json"))
                ]))
            case None => ()
        }
    })

    /* body: {"action": "whitelist-add|whitelist-remove|op|deop|ban|pardon|kick", "player": "Steve"} */
    router.post("/api/v1/instances/{id}/players/{action}", { ctx, md =>
        if (!Auth.guard(ctx)) {
            return
        }
        let action = md.matchString("action")
        match (Instances.findOr404(ctx, md.matchString("id"))) {
            case Some(ins) =>
                if (ins.game != "minecraft") {
                    HttpUtil.fail(ctx, 6100, "玩家管理当前仅支持 Minecraft")
                    return
                }
                if (Docker.status(ins.containerName()) != "running") {
                    HttpUtil.fail(ctx, 3005, "实例未在运行（玩家操作需要在线执行）")
                    return
                }
                match (Players.rconFor(action, "")) {
                    case None => HttpUtil.fail(ctx, 404, "未知操作: ${action}")
                    case Some(_) => ()
                }
                let body = HttpUtil.bodyJson(ctx)
                let player = HttpUtil.str(body, "player", "").trimAscii()
                if (player == "") {
                    HttpUtil.fail(ctx, 6101, "player 不能为空")
                    return
                }
                let cmdArgs = match (Players.rconFor(action, player)) {
                    case Some(a) => a
                    case None => return
                }
                let r = Docker.exec(ins.containerName(), cmdArgs)
                if (r.ok()) {
                    HttpUtil.okMsg(ctx, "已执行 ${action}: ${player}")
                } else {
                    HttpUtil.fail(ctx, 6102, "执行失败: ${(r.stderr + r.stdout).trimAscii()}")
                }
            case None => ()
        }
    })
}
