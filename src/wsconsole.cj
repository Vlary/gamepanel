package gamepanel

/*
 * 实时控制台（WebSocket）：
 *   GET /api/v1/instances/{id}/ws-console?token=<登录token>
 * 建立 WS 后：后台持续执行 `docker logs -f`，把新增日志实时推给浏览器；
 * 浏览器也可直接发文本帧 = 控制台命令（双向实时）。
 * 鉴权说明：浏览器原生 WebSocket 不能携带 Authorization 头，token 经 query 传入。
 */

import stdx.net.http.*
import std.process.*
import std.io.*
import std.collection.*

public func registerWsRoutes(): Unit {
    router.get("/api/v1/instances/{id}/ws-console", { ctx, md =>
        let token = queryParam(ctx, "token")
        match (Auth.checkToken(token)) {
            case Some(_) => ()
            case None =>
                HttpUtil.fail(ctx, 401, "未登录")
                return
        }
        match (Instances.findOr404(ctx, md.matchString("id"))) {
            case Some(ins) =>
                // 升级为 WebSocket（阻塞握手）
                let conn: WebSocket
                try {
                    conn = WebSocket.upgradeFromServer(ctx)
                } catch (e: Exception) {
                    println("[ws] 升级失败: ${e.message}")
                    return
                }
                // 日志跟随流（容器 stdout + stderr 各一条管道）
                var args = ArrayList<String>(["logs", "-f", "--tail", "100", "--timestamps", ins.containerName()])
                if (ins.node != "" && ins.node != "local") {
                    args = ArrayList<String>(["--context", ins.node, "logs", "-f", "--tail", "100", "--timestamps", ins.containerName()])
                }
                var proc: ?SubProcess = None
                try {
                    let p = Process.start(Config.dockerBin, args.toArray(),
                        stdOut: ProcessRedirect.Pipe,
                        stdErr: ProcessRedirect.Pipe)
                    proc = Some(p)
                } catch (e: Exception) {
                    println("[ws] 启动日志流失败: ${e.message}")
                }
                // 推送线程：读 docker logs 输出 -> WS 帧
                match (proc) {
                    case Some(p) =>
                        spawn {
                            pumpLog(p.stdOutPipe, conn)
                        }
                        spawn {
                            pumpLog(p.stdErrPipe, conn)
                        }
                    case None => ()
                }
                // 读循环：接收浏览器命令 / 关闭帧
                while (true) {
                    try {
                        let frame = conn.read()
                        if (frame.frameType == WebSocketFrameType.CloseWebFrame) {
                            break
                        }
                        if (frame.frameType == WebSocketFrameType.TextWebFrame) {
                            let text = String.fromUtf8(frame.payload)
                            if (text != "") {
                                let (sent, echo) = ConsolePipe.send(ins, text)
                                if (sent && echo != "") {
                                    conn.write(WebSocketFrameType.TextWebFrame, (echo + "\n").toArray())
                                }
                                if (!sent) {
                                    conn.write(WebSocketFrameType.TextWebFrame, ("[面板] 命令未能送达（实例可能未运行）\n").toArray())
                                }
                            }
                        }
                    } catch (_: Exception) {
                        break
                    }
                }
                // 清理
                match (proc) {
                    case Some(p) =>
                        try {
                            p.terminate(force: true)
                        } catch (_: Exception) {
                            ()
                        }
                    case None => ()
                }
            case None => ()
        }
    })
}

func pumpLog(stream: InputStream, conn: WebSocket): Unit {
    try {
        while (true) {
            let buf = Array<Byte>(4096, repeat: 0)
            let n = stream.read(buf)
            if (n <= 0) {
                break
            }
            conn.write(WebSocketFrameType.TextWebFrame, buf[..n])
        }
    } catch (_: Exception) {
        ()   // 连接关闭，退出推送
    }
}
