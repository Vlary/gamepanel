#!/usr/bin/env python3
"""
游戏方舟 全量测试第 3 轮：Minecraft 实例全生命周期 E2E（数据完整性级）。

与第 2 轮（接口层）不同，本轮验证每步操作后**数据真实落盘与生效**：
配置改写→重启生效、RCON 白名单落盘、备份恢复内容回真、世界重置保护备份、
任务执行历史持久化、监控采样真实存在。

前置：隔离面板已启动，宿主可访问其实例数据目录（GP_DATA 环境对应路径，
默认 /tmp/gp-e2e —— 与启动面板时传入的 GP_DATA 保持一致，可用环境变量覆盖）。
"""

import json
import os
import sys
import time
import urllib.request
import urllib.error

BASE = os.environ.get("GP_TEST_BASE", "http://127.0.0.1:8090")
DATA_ROOT = os.environ.get("GP_TEST_DATA", "/tmp/gp-e2e")
PASS = 0
FAIL = 0
FAILURES = []


def call(method, path, token=None, body=None):
    url = BASE + "/api/v1" + path
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(url, data=data, method=method)
    if token:
        req.add_header("Authorization", "Bearer " + token)
    if data:
        req.add_header("Content-Type", "application/json")
    try:
        resp = urllib.request.urlopen(req, timeout=60)
        raw = resp.read().decode()
        return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        raw = e.read().decode()
        try:
            return json.loads(raw) if raw else {}
        except json.JSONDecodeError:
            return {"raw": raw}


def check(name, cond, detail=""):
    global PASS, FAIL
    if cond:
        PASS += 1
    else:
        FAIL += 1
        FAILURES.append(f"{name}  {detail}")
        print(f"  ✗ {name}  {detail}")


def login():
    r = call("POST", "/auth/login", body={"username": "admin", "password": "admin123"})
    return r["data"]["token"]


def wait_ready(token, iid, timeout_s=200, need=True):
    for _ in range(timeout_s // 6):
        time.sleep(6)
        r = call("GET", f"/instances/{iid}", token=token)
        if r.get("data", {}).get("ready") == need:
            return True
    return False


def stop_and_wait(token, iid):
    call("POST", f"/instances/{iid}/stop", token=token)
    for _ in range(45):
        time.sleep(2)
        r = call("GET", f"/instances/{iid}", token=token)
        if r.get("data", {}).get("status") != "running":
            return True
    return False


def read_file(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


def main():
    token = login()

    # ---------- 1. 创建并就绪 ----------
    print("== 1. 创建与就绪 ==")
    r = call("POST", "/instances", token=token,
             body={"game": "minecraft", "version": "paper-1.21", "name": "E2E验证服", "port": 25591, "memoryMB": 2048,
                  "extraEnv": {"ONLINE_MODE": "FALSE"}})
    check("创建实例", r.get("code") == 0)
    lst = call("GET", "/instances", token=token)["data"]
    ins = next(i for i in lst if i["name"] == "E2E验证服")
    iid = ins["id"]
    datadir = os.path.join(DATA_ROOT, "instances", iid)
    check("数据目录已创建", os.path.isdir(datadir))
    check("就绪检测", wait_ready(token, iid))

    # ---------- 2. 配置修改 → 重启生效 ----------
    print("== 2. 配置改写生效 ==")
    r = call("PUT", f"/instances/{iid}/game-config", token=token,
             body={"values": {"motd": "E2E-VERIFIED", "view-distance": "7", "spawn-monsters": "false"}})
    check("配置写入接口", r.get("code") == 0)
    time.sleep(1)
    props = read_file(os.path.join(datadir, "server.properties"))
    check("MOTD 已落盘", "motd=E2E-VERIFIED" in props)
    check("视距已落盘", "view-distance=7" in props)
    r = call("POST", f"/instances/{iid}/restart", token=token)
    check("重启指令", r.get("code") == 0)
    time.sleep(10)
    check("重启后再次就绪", wait_ready(token, iid, timeout_s=240))
    props2 = read_file(os.path.join(datadir, "server.properties"))
    check("重启后配置保持", "motd=E2E-VERIFIED" in props2)

    # ---------- 3. RCON 玩家操作落盘 ----------
    print("== 3. RCON 白名单落盘 ==")
    # MC 1.20+ 要求 white-list=true 才接受 whitelist add（离线模式下任意玩家名可加）
    call("PUT", f"/instances/{iid}/game-config", token=token, body={"values": {"white-list": "true"}})
    call("POST", f"/instances/{iid}/restart", token=token)
    time.sleep(10)
    check("白名单开启后重启就绪", wait_ready(token, iid, timeout_s=240))
    r = call("POST", f"/instances/{iid}/players/whitelist-add", token=token, body={"player": "E2ETester"})
    check("RCON 加白", r.get("code") == 0, str(r.get("msg", ""))[:80])
    time.sleep(3)
    wl = read_file(os.path.join(datadir, "whitelist.json"))
    check("whitelist.json 含新玩家", "E2ETester" in wl or "e2etester" in wl.lower(), wl[:80])
    r = call("GET", f"/instances/{iid}/players", token=token)
    names = [p["name"] for p in r.get("data", {}).get("whitelist", [])]
    check("玩家 API 列表同步", any("E2E" in n.upper() for n in names), str(names))

    # ---------- 4. 快照 → 停止 → 恢复（内容回真） ----------
    print("== 4. 备份恢复闭环 ==")
    # 在存档里放一个标记文件（模拟玩家数据），快照后删掉，恢复后应回来
    world_extra = os.path.join(datadir, "world", "e2e-marker.txt")
    with open(world_extra, "w") as f:
        f.write("before-snapshot")
    r = call("POST", f"/instances/{iid}/snapshot", token=token, body={"name": "E2E回归点"})
    check("创建快照", r.get("code") == 0)
    time.sleep(5)
    recs = call("GET", f"/instances/{iid}/records?kind=snapshot", token=token)["data"]
    check("快照记录存在", len(recs) >= 1)
    rid = recs[0]["id"]
    os.remove(world_extra)
    check("停止实例", stop_and_wait(token, iid))
    r = call("POST", f"/records/{rid}/restore", token=token)
    check("恢复任务下发", r.get("code") == 0)
    time.sleep(6)
    check("恢复后标记文件回归", os.path.exists(world_extra))
    # 恢复产生的保护快照
    recs2 = call("GET", f"/instances/{iid}/records?kind=snapshot", token=token)["data"]
    check("保护快照已生成", len(recs2) >= 2)

    # ---------- 5. 世界重置（保护备份 + 目录重建） ----------
    print("== 5. 世界重置 ==")
    r = call("POST", f"/instances/{iid}/worlds/world_nether/reset", token=token)
    check("重置末地/下界世界", r.get("code") == 0, str(r))
    check("世界目录已删除", not os.path.exists(os.path.join(datadir, "world_nether")))
    backups = call("GET", f"/instances/{iid}/records?kind=backup", token=token)["data"]
    check("重置前保护备份存在", len(backups) >= 1)
    check("重启实例", call("POST", f"/instances/{iid}/start", token=token).get("code") == 0)
    check("重启后再次就绪", wait_ready(token, iid, timeout_s=240))
    check("主世界不受重置影响", os.path.exists(os.path.join(datadir, "world")))
    check("主世界标记仍在", os.path.exists(os.path.join(datadir, "world", "e2e-marker.txt")))

    # ---------- 6. 计划任务执行历史 ----------
    print("== 6. 任务执行历史 ==")
    r = call("POST", "/tasks", token=token,
             body={"name": "E2E任务", "instanceId": iid, "action": "snapshot", "cron": "0 4 * * *", "keepCount": 2})
    tid = None
    for t in call("GET", "/tasks", token=token)["data"]:
        if t["name"] == "E2E任务":
            tid = t["id"]
    check("任务已创建", tid is not None)
    call("POST", f"/tasks/{tid}/run", token=token)
    time.sleep(8)
    t = next(t for t in call("GET", "/tasks", token=token)["data"] if t["id"] == tid)
    check("执行历史已记录", len(t.get("history", [])) >= 1 and t["history"][-1]["ok"] is True,
          json.dumps(t.get("history", [])[-1:], ensure_ascii=False))

    # ---------- 7. 监控采样 ----------
    print("== 7. 监控采样 ==")
    r = call("GET", f"/instances/{iid}/metrics", token=token)
    pts = r.get("data", [])
    check("监控曲线有采样点", len(pts) >= 2, f"{len(pts)} 点")

    # ---------- 8. 日志与命令 ----------
    print("== 8. 控制台 ==")
    r = call("GET", f"/instances/{iid}/logs?tail=100", token=token)
    check("日志含启动完成标记", "Done" in r.get("data", {}).get("logs", ""))
    r = call("POST", f"/instances/{iid}/command", token=token, body={"cmd": "say e2e-check"})
    check("RCON 命令发送", r.get("code") == 0, json.dumps(r, ensure_ascii=False)[:100])
    # say 类命令无 RCON 回显，用 list 验证同步回显通道（data.output）
    r = call("POST", f"/instances/{iid}/command", token=token, body={"cmd": "list"})
    check("RCON 同步回显", r.get("code") == 0 and "players online" in str(r.get("data", {}).get("output", "")),
          json.dumps(r, ensure_ascii=False)[:120])

    # ---------- 9. 清理 ----------
    print("== 9. 清理 ==")
    call("DELETE", f"/tasks/{tid}", token=token)
    stop_and_wait(token, iid)
    r = call("POST", f"/instances/{iid}/delete", token=token)
    check("删除实例（含数据）", r.get("code") == 0)
    check("数据目录已移除", not os.path.exists(datadir))

    print(f"\n{'=' * 40}\nE2E 测试：通过 {PASS}，失败 {FAIL}")
    for f in FAILURES:
        print("  -", f)
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    main()
