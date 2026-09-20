package gamepanel

/*
 * Docker CLI 封装：面板不直接依赖 Docker Engine API，而是调用 docker 命令行。
 * 好处：与 Docker 版本解耦、权限模型与运维习惯一致（用户在 docker 组即可）、便于排查。
 * 所有方法同步执行并返回文本结果，失败信息原样透传给前端。
 */

import std.process.*
import std.fs.*
import std.sync.*
import std.collection.*

/* 一次 docker 命令的结果 */
public class CmdResult {
    public var exitCode: Int64 = 0
    public var stdout = ""
    public var stderr = ""

    public init() {}

    public func ok(): Bool {
        return exitCode == 0
    }
}

public class Docker {
    /* 执行任意 docker 子命令；node 为空或 local 走本机，否则经 docker context 远程执行 */
    public static func run(args: Array<String>, node!: String = "local"): CmdResult {
        let r = CmdResult()
        try {
            var finalArgs = args
            if (node != "" && node != "local") {
                let buf = ArrayList<String>(["--context", node])
                for (a in args) {
                    buf.add(a)
                }
                finalArgs = buf.toArray()
            }
            let (code, out, err) = Process.runOutput(Config.dockerBin, finalArgs)
            r.exitCode = code
            r.stdout = String.fromUtf8(out)
            r.stderr = String.fromUtf8(err)
        } catch (e: Exception) {
            r.exitCode = -1
            r.stderr = "无法执行 ${Config.dockerBin}: ${e.message}（请确认已安装 Docker 且当前用户有权限）"
        }
        return r
    }

    public static func version(): String {
        let r = run(["--version"])
        if (r.ok()) {
            return r.stdout.trimAscii()
        }
        return ""
    }

    /* 容器是否存在 */
    public static func exists(name: String, node!: String = "local"): Bool {
        return run(["inspect", name], node: node).ok()
    }

    /* 容器状态：running / exited / paused / created / missing */
    public static func status(name: String, node!: String = "local"): String {
        let r = run(["inspect", "--format", "{{.State.Status}}", name], node: node)
        if (!r.ok()) {
            return "missing"
        }
        return r.stdout.trimAscii()
    }

    public static func pull(image: String, node!: String = "local"): CmdResult {
        return run(["pull", image], node: node)
    }

    public static func start(name: String, node!: String = "local"): CmdResult {
        return run(["start", name], node: node)
    }

    public static func stop(name: String, node!: String = "local"): CmdResult {
        return run(["stop", "-t", "30", name], node: node)
    }

    public static func restart(name: String, node!: String = "local"): CmdResult {
        return run(["restart", "-t", "30", name], node: node)
    }

    public static func forceRemove(name: String, node!: String = "local"): CmdResult {
        return run(["rm", "-f", name], node: node)
    }

    /* 取容器日志（尾部 tail 行） */
    public static func logs(name: String, tail: Int64, node!: String = "local"): String {
        let r = run(["logs", "--tail", tail.toString(), "--timestamps", name], node: node)
        if (!r.ok()) {
            return r.stderr.trimAscii()
        }
        return r.stdout
    }

    /*
     * 容器资源占用：docker stats --no-stream
     * 返回 (cpuPercent文本, memUsage文本)；容器不在运行时返回空
     */
    public static func stats(name: String, node!: String = "local"): (String, String) {
        let r = run(["stats", "--no-stream", "--format", "{{.CPUPerc}}|{{.MemUsage}}", name], node: node)
        if (!r.ok()) {
            return ("", "")
        }
        let line = r.stdout.trimAscii()
        let parts = line.split("|")
        if (parts.size >= 2) {
            return (parts[0], parts[1])
        }
        return ("", "")
    }

    /* 按模板参数创建并启动容器（-d 后台运行） */
    public static func runInstance(ins: Instance): CmdResult {
        let args = ArrayList<String>()
        args.add("run")
        args.add("-d")
        // 接入 EasyTier 组网：与组网容器共享网络栈（host 网络），游戏直接监听
        // 虚拟 IP 与宿主全部网卡；此时不做 -p 端口映射（host 模式无意义）
        if (ins.useMesh) {
            if (status(ET_CONTAINER) != "running") {
                let r = CmdResult()
                r.exitCode = -1
                r.stderr = "组网未运行：请先在「联机组网」页启用 EasyTier"
                return r
            }
            args.add("--network")
            args.add("container:" + ET_CONTAINER)
        }
        args.add("-i")   // 保持 stdin 打开：控制台命令下发依赖 docker attach 写入
        args.add("--name")
        args.add(ins.containerName())
        if (ins.autoStart) {
            args.add("--restart")
            args.add("unless-stopped")
        }
        if (ins.memoryMB > 0) {
            args.add("--memory")
            args.add("${ins.memoryMB}m")
        }
        if (ins.cpus > 0.0) {
            args.add("--cpus")
            args.add(ins.cpus.toString())
        }
        if (!ins.useMesh) {
            for (p in ins.ports) {
                args.add("-p")
                args.add(p)
            }
        }
        // useMesh 说明：与组网容器共享宿主网络栈，游戏监听容器内端口（无 NAT 映射）。
        // 玩家连接地址 = 虚拟IP:容器内端口。
        args.add("-v")
        args.add("${ins.dataDir}:${ins.mountPath}")
        for ((k, v) in ins.mergedEnv()) {
            args.add("-e")
            args.add("${k}=${v}")
        }
        args.add(ins.image)
        // 僵尸毁灭工程（lacledeslan 镜像）：自定义启动命令；servername 固定 servertest
        // 与游戏配置 schema（Server/servertest.ini）对齐；ADMIN_PASSWORD 转启动参数
        if (ins.game == "zomboid") {
            args.add("/app/start-server.sh")
            args.add("-servername")
            args.add("servertest")
            let adminPass = ins.extraEnv.get("ADMIN_PASSWORD") ?? ""
            if (adminPass != "") {
                args.add("-adminpassword")
                args.add(adminPass)
            }
        }
        // 泰拉瑞亚开箱即玩：数据目录还没有世界文件时附加 -autocreate 2（中等世界），
        // 服务器自动按 WORLD_NAME 生成世界并直接开服（不再停在交互菜单）
        if (ins.game == "terraria" && ins.mountPath != "") {
            var hasWorld = false
            try {
                for (fi in Directory.readFrom(ins.dataDir)) {
                    if (!fi.isDirectory() && fi.name.endsWith(".wld")) {
                        hasWorld = true
                        break
                    }
                }
            } catch (_: Exception) {
                ()
            }
            if (!hasWorld) {
                args.add("-autocreate")
                args.add("2")
                println("[instance] ${ins.id} 无世界文件，附加 -autocreate 2 自动建世界")
            }
        }
        return run(args.toArray(), node: ins.node)
    }

    /* 在容器里执行命令（用于 Minecraft 的 rcon-cli 控制台） */
    public static func exec(name: String, cmdArgs: Array<String>, node!: String = "local"): CmdResult {
        let full = ArrayList<String>(["exec", name])
        for (a in cmdArgs) {
            full.add(a)
        }
        return run(full.toArray(), node: node)
    }
}

/*
 * 控制台命令下发通道。
 * Minecraft 镜像内置 rcon-cli：docker exec <容器> rcon-cli "<命令>"，同步回显；
 * 其余游戏读 stdin 控制台：为每个运行中的实例维持一个 `docker attach` 进程，
 * 写命令到它的 stdin 即等于在服务器控制台敲命令。
 */
public class ConsolePipe {
    private static let mutex = Mutex()
    private static let pipes = HashMap<String, SubProcess>()

    public static func attach(ins: Instance) {
        mutex.lock()
        detachLocked(ins.id)
        try {
            var args = ["attach", ins.containerName()]
            if (ins.node != "" && ins.node != "local") {
                let buf = ArrayList<String>(["--context", ins.node])
                buf.add("attach")
                buf.add(ins.containerName())
                args = buf.toArray()
            }
            let p = Process.start(Config.dockerBin, args,
                stdIn: ProcessRedirect.Pipe,
                stdOut: ProcessRedirect.Discard,
                stdErr: ProcessRedirect.Discard)
            pipes.add(ins.id, p)
        } catch (e: Exception) {
            println("[console] attach ${ins.id} 失败: ${e.message}")
        }
        mutex.unlock()
    }

    public static func detach(id: String) {
        mutex.lock()
        detachLocked(id)
        mutex.unlock()
    }

    private static func detachLocked(id: String) {
        match (pipes.get(id)) {
            case Some(p) =>
                try {
                    p.terminate(force: true)
                } catch (_: Exception) {
                    ()
                }
                pipes.remove(id)
            case None => ()
        }
    }

    /* 向实例控制台发送一条命令 */
    public static func send(ins: Instance, cmd: String): Bool {
        // Minecraft 走 rcon-cli（同步拿到回显）
        if (ins.game == "minecraft") {
            let r = Docker.exec(ins.containerName(), ["rcon-cli", cmd], node: ins.node)
            if (r.ok()) {
                return true
            }
        }
        // 通用路径：写入 attach 进程 stdin
        mutex.lock()
        let p = pipes.get(ins.id)
        mutex.unlock()
        match (p) {
            case Some(proc) =>
                try {
                    proc.stdInPipe.write((cmd + "\n").toArray())
                    return true
                } catch (e: Exception) {
                    println("[console] 写入 ${ins.id} 失败: ${e.message}")
                }
            case None => ()
        }
        // 兜底：容器在运行但 attach 池没有，现场 attach 再补发一次
        if (Docker.status(ins.containerName(), node: ins.node) == "running") {
            attach(ins)
            sleep(500 * Duration.millisecond)
            mutex.lock()
            let p2 = pipes.get(ins.id)
            mutex.unlock()
            match (p2) {
                case Some(proc) =>
                    try {
                        proc.stdInPipe.write((cmd + "\n").toArray())
                        return true
                    } catch (_: Exception) {
                        return false
                    }
                case None => return false
            }
        }
        return false
    }
}
