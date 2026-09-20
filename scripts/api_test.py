#!/usr/bin/env python3
"""
游戏方舟 全量测试第 2 轮：REST API 全端点自动化测试。

前置：面板已在隔离数据目录启动（GP_DATA=临时目录，默认账号 admin/admin123）。
用法：python3 scripts/api_test.py [base_url]
     base_url 默认 http://127.0.0.1:8090

覆盖：鉴权（401/限速/改密）、权限（viewer/operator/admin 边界）、参数校验、
正常流与异常流、按游戏定制接口的跨游戏拒绝、路径穿越防护、生命周期端点。
"""

import json
import sys
import time
import urllib.request
import urllib.error

BASE = sys.argv[1] if len(sys.argv) > 1 else "http://127.0.0.1:8090"
PASS = 0
FAIL = 0
FAILURES = []


def call(method, path, token=None, body=None, raw_text=False):
    url = BASE + "/api/v1" + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    if token:
        req.add_header("Authorization", "Bearer " + token)
    if data:
        req.add_header("Content-Type", "application/json")
    try:
        resp = urllib.request.urlopen(req, timeout=30)
        raw = resp.read().decode()
        if raw_text:
            return resp.status, raw
        return resp.status, json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return e.code, json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            return e.code, {"raw": raw}
    except Exception as e:  # noqa: BLE001
        return -1, {"msg": str(e)}


def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
    else:
        FAIL += 1
        FAILURES.append(f"{name}  {detail}")
        print(f"  ✗ {name}  {detail}")


def section(title):
    print(f"== {title} ==")


def main():
    # ---------- 1. 健康检查（免鉴权） ----------
    section("健康检查")
    st, r = call("GET", "/health")
    check("health 返回 ok", st == 200 and r.get("data", {}).get("status") == "ok")

    # ---------- 2. 鉴权 ----------
    section("鉴权")
    st, r = call("GET", "/overview")
    check("无 token 业务码 401", r.get("code") == 401, f"got {r}")
    st, r = call("POST", "/auth/login", body={"username": "admin", "password": "wrong"})
    check("错误密码 1001", r.get("code") == 1001)
    st, r = call("POST", "/auth/login", body={"username": "ghost", "password": "x"})
    check("不存在用户 1001", r.get("code") == 1001)
    st, r = call("POST", "/auth/login", body={"username": "admin", "password": "admin123"})
    check("正确登录", st == 200 and r.get("code") == 0 and r["data"]["token"])
    admin = r["data"]["token"]

    # ---------- 3. 端口预检 ----------
    section("端口预检")
    st, r = call("GET", "/port-check?port=abc", token=admin)
    check("非数字端口 2101", r.get("code") == 2101)
    st, r = call("GET", "/port-check?port=70000", token=admin)
    check("越界端口 2102", r.get("code") == 2102)
    st, r = call("GET", f"/port-check?port={BASE.rsplit(':', 1)[1]}", token=admin)
    check("面板自身端口被占用", r.get("code") == 0 and r["data"]["available"] is False and r["data"]["systemInUse"])

    # ---------- 4. 模板与总览 ----------
    section("模板与总览")
    st, r = call("GET", "/templates", token=admin)
    games = [t["key"] for t in r.get("data", [])]
    check("四游戏模板齐全", set(games) >= {"minecraft", "dst", "terraria", "zomboid"}, str(games))
    st, r = call("GET", "/overview", token=admin)
    check("overview 字段齐全", all(k in r.get("data", {}) for k in
          ("dockerOk", "instanceCount", "diskAvailGB", "diskTotalGB", "dataUsedMB")))

    # ---------- 5. 用户与权限 ----------
    section("用户与权限")
    st, r = call("POST", "/users", token=admin, body={"username": "op2", "password": "op2pass123", "role": "operator"})
    check("创建 operator", r.get("code") == 0)
    st, r = call("POST", "/users", token=admin, body={"username": "v2", "password": "v2pass1234", "role": "viewer"})
    check("创建 viewer", r.get("code") == 0)
    st, r = call("POST", "/auth/login", body={"username": "v2", "password": "v2pass1234"})
    viewer = r["data"]["token"]
    st, r = call("POST", "/auth/login", body={"username": "op2", "password": "op2pass123"})
    oper = r["data"]["token"]

    st, r = call("GET", "/overview", token=viewer)
    check("viewer 可读 overview", r.get("code") == 0)
    st, r = call("POST", "/instances", token=viewer, body={"game": "minecraft", "version": "paper-1.21", "name": "x"})
    check("viewer 建实例被拒", r.get("code") in (403, 1001, 401), f"code={r.get('code')}")
    st, r = call("GET", "/users", token=viewer)
    check("viewer 看用户列表被拒", r.get("code") != 0, f"code={r.get('code')}")
    st, r = call("GET", "/sessions", token=viewer)
    check("viewer 看会话被拒", r.get("code") != 0, f"code={r.get('code')}")

    # 会话管理
    st, r = call("GET", "/sessions", token=admin)
    check("admin 会话列表", r.get("code") == 0 and len(r.get("data", [])) >= 3)
    st, r = call("DELETE", "/sessions/zzzzzzzz", token=admin)
    check("踢不存在会话 404", r.get("code") == 404)

    # 改密
    st, r = call("POST", "/auth/change-password", token=viewer, body={"oldPassword": "bad", "newPassword": "newpass1234"})
    check("改密旧密码错", r.get("code") == 1001)
    st, r = call("POST", "/auth/change-password", token=viewer, body={"oldPassword": "v2pass1234", "newPassword": "short"})
    check("改密强度不足", r.get("code") == 1004)
    st, r = call("POST", "/auth/change-password", token=viewer, body={"oldPassword": "v2pass1234", "newPassword": "v2pass5678"})
    check("改密成功", r.get("code") == 0)
    st, r = call("POST", "/auth/login", body={"username": "v2", "password": "v2pass5678"})
    check("新密码可登录", r.get("code") == 0)
    viewer = r["data"]["token"]

    # ---------- 6. 登录限速 ----------
    section("登录限速")
    locked = False
    for _ in range(6):
        st, r = call("POST", "/auth/login", body={"username": "op2", "password": "bad"})
        if r.get("code") == 1002:
            locked = True
            break
    check("连续失败触发锁定(1002)", locked)
    st, r = call("POST", "/auth/login", body={"username": "op2", "password": "op2pass123"})
    check("锁定期间正确密码也拒绝", r.get("code") != 0)

    # ---------- 7. 实例生命周期 ----------
    section("实例生命周期")
    st, r = call("POST", "/instances", token=admin,
                 body={"game": "minecraft", "version": "paper-1.21", "name": "API测试服", "port": 25590, "memoryMB": 2048})
    check("创建实例", r.get("code") == 0)
    st, r = call("GET", "/instances", token=admin)
    ins = next((i for i in r["data"] if i["name"] == "API测试服"), None)
    check("实例出现在列表且带 ready 字段", ins is not None and "ready" in ins)
    iid = ins["id"]
    # 等待就绪（日志 Done），RCON 与存档依赖
    print("  等待实例就绪…")
    ready = False
    for _ in range(30):
        time.sleep(6)
        st, r = call("GET", f"/instances/{iid}", token=admin)
        if r.get("data", {}).get("ready"):
            ready = True
            break
    check("实例就绪检测", ready)
    st, r = call("GET", f"/instances/{iid}", token=admin)
    check("实例详情", r.get("code") == 0)
    st, r = call("GET", f"/instances/{iid}/logs?tail=50", token=admin)
    check("日志读取", r.get("code") == 0 and "logs" in r.get("data", {}))
    st, r = call("GET", f"/instances/{iid}/metrics", token=admin)
    check("监控数据", r.get("code") == 0)
    st, r = call("POST", f"/instances/{iid}/command", token=admin, body={"cmd": "list"})
    check("控制台命令（RCON）", r.get("code") == 0)
    st, r = call("PUT", f"/instances/{iid}", token=admin,
                 body={"name": "API测试服", "memoryMB": 3072, "autoStart": True})
    check("更新设置重建", r.get("code") == 0)
    st, r = call("POST", f"/instances/{iid}/stop", token=admin)
    check("停止实例", r.get("code") == 0)
    time.sleep(6)
    st, r = call("POST", f"/instances/{iid}/start", token=admin)
    check("启动实例", r.get("code") == 0)

    # ---------- 8. 文件管理 ----------
    section("文件管理")
    st, r = call("GET", f"/instances/{iid}/files?path=", token=admin)
    check("根目录列表", r.get("code") == 0 and "files" in r.get("data", {}))
    st, r = call("GET", f"/instances/{iid}/files?path=../../etc", token=admin)
    check("路径穿越被拦", r.get("data", {}).get("error") or r.get("code") != 0)
    st, r = call("PUT", f"/instances/{iid}/file?path=test-api.txt", token=admin)
    # PUT 原始 body —— call 不支持非 JSON，单独发
    req = urllib.request.Request(f"{BASE}/api/v1/instances/{iid}/file?path=test-api.txt",
                                 data=b"hello api test", method="PUT")
    req.add_header("Authorization", "Bearer " + admin)
    st = urllib.request.urlopen(req, timeout=10).status
    check("写文件", st == 200)
    st, text = call("GET", f"/instances/{iid}/file?path=test-api.txt", token=admin, raw_text=True)
    check("读文件内容一致", text == "hello api test", f"got {text!r}")
    st, r = call("POST", f"/instances/{iid}/file-action", token=admin,
                 body={"action": "rename", "path": "test-api.txt", "newName": "test-2.txt"})
    check("重命名", r.get("code") == 0)
    st, r = call("POST", f"/instances/{iid}/file-action", token=admin, body={"action": "delete", "path": "test-2.txt"})
    check("删除文件", r.get("code") == 0)
    st, r = call("POST", f"/instances/{iid}/file-action", token=admin,
                 body={"action": "mkdir", "path": "dir-a"})
    check("新建目录", r.get("code") == 0)
    st, r = call("POST", f"/instances/{iid}/file-action", token=admin, body={"action": "delete", "path": "dir-a"})
    check("删除目录", r.get("code") == 0)

    # ---------- 9. 备份与快照 ----------
    section("备份与快照")
    st, r = call("POST", f"/instances/{iid}/snapshot", token=admin, body={"name": "API快照"})
    check("创建快照", r.get("code") == 0)
    time.sleep(4)
    st, r = call("GET", f"/instances/{iid}/records?kind=snapshot", token=admin)
    check("快照列表", r.get("code") == 0 and len(r.get("data", [])) >= 1)
    rid = r["data"][0]["id"]
    st, r = call("GET", f"/records/{rid}/preview", token=admin)
    check("归档预览", r.get("code") == 0 and r["data"]["total"] >= 1)
    st, r = call("POST", f"/records/{rid}/restore", token=admin)
    check("运行中恢复被拦", r.get("code") == 4002)
    st, r = call("DELETE", f"/records/{rid}", token=admin)
    check("删除归档", r.get("code") == 0)
    st, r = call("GET", f"/records/r-no-such/preview", token=admin)
    check("预览不存在归档 404", r.get("code") == 404)

    # ---------- 10. 游戏配置 ----------
    section("游戏配置")
    st, r = call("GET", f"/instances/{iid}/game-config", token=admin)
    check("配置读取含分组", r.get("code") == 0 and any("group" in f for f in r["data"]["fields"]))
    st, r = call("PUT", f"/instances/{iid}/game-config", token=admin,
                 body={"values": {"view-distance": "8"}})
    check("配置写入", r.get("code") == 0)

    # ---------- 11. 按游戏定制接口（跨游戏拒绝） ----------
    section("按游戏定制接口")
    st, r = call("GET", f"/instances/{iid}/dst-shards", token=admin)
    check("MC 访问 DST 接口被拒 4500", r.get("code") == 4500)
    st, r = call("GET", f"/instances/{iid}/terraria-worlds", token=admin)
    check("MC 访问泰拉接口被拒 4600", r.get("code") == 4600)
    st, r = call("GET", f"/instances/{iid}/pz-presets", token=admin)
    check("MC 访问 PZ 接口被拒 4700", r.get("code") == 4700)
    st, r = call("GET", f"/instances/{iid}/worlds", token=admin)
    check("MC 世界列表", r.get("code") == 0 and "eula" in r.get("data", {}))

    # ---------- 12. 计划任务 ----------
    section("计划任务")
    st, r = call("GET", "/cron-preview?expr=0%204%20*%20*%20*", token=admin)
    check("cron 预览合法", r.get("code") == 0 and len(r["data"]["runs"]) == 5)
    st, r = call("GET", "/cron-preview?expr=bad", token=admin)
    check("cron 预览非法 5001", r.get("code") == 5001)
    st, r = call("POST", "/tasks", token=admin,
                 body={"name": "API任务", "instanceId": iid, "action": "snapshot", "cron": "0 4 * * *", "keepCount": 3})
    check("创建任务", r.get("code") == 0)
    st, r = call("GET", "/tasks", token=admin)
    task = next((t for t in r["data"] if t["name"] == "API任务"), None)
    check("任务列表含 nextRun", task is not None and task.get("nextRun"))
    tid = task["id"]
    st, r = call("PUT", f"/tasks/{tid}", token=admin, body={"name": "API任务2", "enabled": True})
    check("任务编辑", r.get("code") == 0)
    st, r = call("POST", f"/tasks/{tid}/run", token=admin)
    check("立即执行", r.get("code") == 0)
    st, r = call("DELETE", f"/tasks/{tid}", token=admin)
    check("删除任务", r.get("code") == 0)

    # ---------- 13. 通知中心 ----------
    section("通知中心")
    st, r = call("GET", "/notifications", token=admin)
    check("通知列表", r.get("code") == 0 and "unread" in r.get("data", {}))
    st, r = call("POST", "/notifications/read-all", token=admin)
    check("全部已读", r.get("code") == 0)
    st, r = call("POST", "/notifications/clear", token=admin)
    check("清空通知", r.get("code") == 0)

    # ---------- 14. 诊断 ----------
    section("诊断")
    st, r = call("GET", "/health-report", token=admin)
    check("健康自检 7 项", r.get("code") == 0 and len(r["data"]) == 7)
    st, r = call("GET", "/storage", token=admin)
    check("存储明细", r.get("code") == 0 and "totalKB" in r.get("data", {}))
    st, r = call("GET", "/health-report", token=viewer)
    check("viewer 访问诊断被拒", r.get("code") != 0, f"code={r.get('code')}")

    # ---------- 15. 组网（未启用态） ----------
    section("组网状态")
    st, r = call("GET", "/easytier/status", token=admin)
    check("组网状态可读", r.get("code") == 0 and "enabled" in r.get("data", {}))

    # ---------- 16. 删除实例 ----------
    section("清理")
    st, r = call("POST", f"/instances/{iid}/stop", token=admin)
    time.sleep(5)
    st, r = call("POST", f"/instances/{iid}/delete", token=admin)
    check("删除实例", r.get("code") == 0)

    # ---------- 汇总 ----------
    print(f"\n{'=' * 40}\nAPI 测试：通过 {PASS}，失败 {FAIL}")
    if FAILURES:
        print("失败项：")
        for f in FAILURES:
            print("  -", f)
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    main()
