package gamepanel

/*
 * 面板配置：全部支持环境变量覆盖，无配置文件，符合"零依赖开箱即用"。
 *   GP_PORT        监听端口（默认 8080）
 *   GP_DATA        数据根目录（默认 <工作目录>/data）
 *   GP_ADMIN_PASS  管理员密码（默认 admin123，生产环境务必修改）
 *   GP_DOCKER      docker 命令路径（默认 docker）
 */

import std.env.*
import std.fs.*
import std.convert.*

public class Config {
    public static let port: UInt16
    public static let adminPass: String
    public static let dockerBin: String
    public static let dataRoot: String

    static init() {
        port = parsePort(getVariable("GP_PORT") ?? "8080")
        adminPass = getVariable("GP_ADMIN_PASS") ?? "admin123"
        dockerBin = getVariable("GP_DOCKER") ?? "docker"
        var root = getVariable("GP_DATA") ?? ""
        if (root == "") {
            root = getWorkingDirectory().toString() + "/data"
        }
        dataRoot = root
    }

    private static func parsePort(s: String): UInt16 {
        try {
            let v = Int64.parse(s)
            if (v > 0 && v < 65536) {
                return UInt16(v)
            }
        } catch (_: Exception) {
            ()
        }
        return 8080
    }
}

/* 数据目录布局：root/{db.json, instances/<id>/, backups/<id>/.tar.gz, snapshots/<id>/} */
public class Paths {
    public static func dbFile(): String {
        return Config.dataRoot + "/db.json"
    }

    public static func instanceDir(id: String): String {
        return Config.dataRoot + "/instances/" + id
    }

    public static func backupDir(id: String): String {
        return Config.dataRoot + "/backups/" + id
    }

    public static func snapshotDir(id: String): String {
        return Config.dataRoot + "/snapshots/" + id
    }

    public static func ensureAll() {
        mkDir(Config.dataRoot)
        mkDir(Config.dataRoot + "/instances")
        mkDir(Config.dataRoot + "/backups")
        mkDir(Config.dataRoot + "/snapshots")
    }

    private static func mkDir(path: String) {
        if (!exists(path)) {
            Directory.create(path, recursive: true)
        }
    }
}
