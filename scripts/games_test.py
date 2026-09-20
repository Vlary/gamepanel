#!/usr/bin/env python3
"""
游戏方舟 全量测试第 4 轮：四游戏定制接口矩阵。

真容器验证按游戏的深度定制接口：
- Minecraft：世界识别/EULA、单世界重置（保护备份 + 目录删除）
- 饥荒 DST：分片识别、洞穴启停（目录迁移）、世界生成预设写入
- 泰拉瑞亚：.wld 世界列表、世界切换（current 标记迁移）
- 僵尸毁灭工程：沙盒预设写入（[SandboxVars] 落盘）
"""

import json
import os
import shutil
import sys
import time
import urllib.request
import urllib.error

BASE = os.environ.get("GP_TEST_BASE", "http://127.0.0.1:8090")
DATA_ROOT = os.environ.get("GP_TEST_DATA", "/tmp/gp-games")
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
        resp = urllib.request.urlopen(req, timeout=120)
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
    return call("POST", "/auth/login", body={"username": "admin", "password": "admin123"})["data"]["token"]


def create(token, game, name, port, extra=None):
    body = {"game": game, "version": "latest", "name": name, "port": port, "memoryMB": 3072}
    if game == "minecraft":
        body["version"] = "paper-1.21"
    if game == "terraria":
        body["version"] = "tshock-latest"
    if extra:
        body.update(extra)
    r = call("POST", "/instances", token=token, body=body)
    lst = call("GET", "/instances", token=token)["data"]
    ins = next((i for i in lst if i["name"] == name), None)
    return ins["id"] if ins else None


def wait_status(token, iid, want, timeout_s=180):
    for _ in range(timeout_s // 5):
        time.sleep(5)
        r = call("GET", f"/instances/{iid}", token=token)
        if r.get("data", {}).get("status") == want:
            return True
        if want != "running" and r.get("data", {}).get("status") == "missing":
            return True
    return False


def stop_and_wait(token, iid):
    call("POST", f"/instances/{iid}/stop", token=token)
    for _ in range(45):
        time.sleep(2)
        if call("GET", f"/instances/{iid}", token=token).get("data", {}).get("status") != "running":
            return True
    return False


def cleanup(token, iid):
    call("POST", f"/instances/{iid}/stop", token=token)
    time.sleep(3)
    call("POST", f"/instances/{iid}/delete", token=token)


def read(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


def main():
    token = login()

    # ---------- Minecraft ----------
    print("== Minecraft：世界与 EULA ==")
    mid = create(token, "minecraft", "矩阵MC服", 25581)
    check("MC 实例创建", mid is not None)
    datadir = os.path.join(DATA_ROOT, "instances", mid)
    for _ in range(30):
        time.sleep(5)
        if os.path.exists(os.path.join(datadir, "world", "session.lock")):
            break
    r = call("GET", f"/instances/{mid}/worlds", token=token)
    d = r.get("data", {})
    check("EULA 已接受", d.get("eula") == "true")
    names = [w["name"] for w in d.get("worlds", [])]
    check("识别主世界", "world" in names, str(names))
    check("停止后重置世界", stop_and_wait(token, mid))
    r = call("POST", f"/instances/{mid}/worlds/world_the_end/reset", token=token)
    check("重置末地成功", r.get("code") == 0, str(r)[:80])
    check("末地目录已删", not os.path.exists(os.path.join(datadir, "world_the_end")))
    recs = call("GET", f"/instances/{mid}/records?kind=backup", token=token)["data"]
    check("重置产生保护备份", len(recs) >= 1)
    r = call("POST", f"/instances/{mid}/worlds/../etc/reset", token=token)
    check("路径穿越被拒", r.get("code") != 0)
    cleanup(token, mid)

    # ---------- 饥荒 DST ----------
    print("== 饥荒 DST：分片与预设 ==")
    did = create(token, "dst", "矩阵DST服", 10997)
    check("DST 实例创建", did is not None)
    ddir = os.path.join(DATA_ROOT, "instances", did, "DoNotStarveTogether", "Cluster_1")
    ok = False
    for _ in range(36):
        time.sleep(5)
        if os.path.exists(os.path.join(ddir, "Caves", "server.ini")):
            ok = True
            break
    check("双分片生成", ok)
    r = call("GET", f"/instances/{did}/dst-shards", token=token)
    d = r.get("data", {})
    shards = {s["name"]: s for s in d.get("shards", [])}
    check("Master+Caves 识别", "Master" in shards and "Caves" in shards, str(list(shards)))
    check("预设列表 4 个", len(d.get("presets", [])) == 4)
    check("停止后停用洞穴", stop_and_wait(token, did))
    r = call("POST", f"/instances/{did}/dst-shards/Caves/toggle", token=token, body={"enabled": False})
    check("洞穴停用", r.get("code") == 0, str(r)[:80])
    check("Caves 已移出", not os.path.exists(os.path.join(ddir, "Caves")))
    r = call("POST", f"/instances/{did}/dst-shards/Caves/toggle", token=token, body={"enabled": True})
    check("洞穴重新启用", r.get("code") == 0)
    check("Caves 目录回归", os.path.exists(os.path.join(ddir, "Caves")))
    r = call("POST", f"/instances/{did}/dst-shards/Master/toggle", token=token, body={"enabled": False})
    check("Master 不可停用", r.get("code") == 4502)
    r = call("POST", f"/instances/{did}/dst-shards/Master/worldgen", token=token, body={"preset": "eternal-winter"})
    check("世界预设写入", r.get("code") == 0)
    lua = read(os.path.join(ddir, "Master", "worldgenoverride.lua"))
    check("预设内容正确", "override_enabled" in lua and "winter" in lua)
    cleanup(token, did)

    # ---------- 泰拉瑞亚 ----------
    print("== 泰拉瑞亚：世界切换 ==")
    tid = create(token, "terraria", "矩阵泰拉服", 7779)
    check("泰拉实例创建", tid is not None)
    tdir = os.path.join(DATA_ROOT, "instances", tid)
    ok = False
    for _ in range(36):
        time.sleep(5)
        if any(f.endswith(".wld") for f in os.listdir(tdir) if os.path.isfile(os.path.join(tdir, f))):
            ok = True
            break
    check("世界文件生成", ok)
    r = call("GET", f"/instances/{tid}/terraria-worlds", token=token)
    d = r.get("data", {})
    worlds = d.get("worlds", [])
    check("世界列表非空", len(worlds) >= 1)
    check("current 标记存在", any(w.get("current") for w in worlds))
    # 复制备用世界并切换
    src = next(f for f in os.listdir(tdir) if f.endswith(".wld"))
    shutil.copy(os.path.join(tdir, src), os.path.join(tdir, "backup-world.wld"))
    r = call("POST", f"/instances/{tid}/terraria-worlds/select", token=token, body={"file": "backup-world.wld"})
    check("切换世界", r.get("code") == 0, str(r)[:80])
    r = call("GET", f"/instances/{tid}/terraria-worlds", token=token)
    cur = next((w["file"] for w in r["data"]["worlds"] if w["current"]), "")
    check("current 已迁移", cur == "backup-world.wld", cur)
    r = call("POST", f"/instances/{tid}/terraria-worlds/select", token=token, body={"file": "../evil.wld"})
    check("穿越文件名被拒", r.get("code") == 4601)
    cleanup(token, tid)

    # ---------- 僵尸毁灭工程 ----------
    print("== PZ：沙盒预设 ==")
    zid = create(token, "zomboid", "矩阵PZ服", 16264)
    check("PZ 实例创建", zid is not None)
    # 不等 LGSM 安装完成（数 GB），预设接口直接操作文件
    time.sleep(10)
    r = call("GET", f"/instances/{zid}/pz-presets", token=token)
    check("预设列表 4 个", r.get("code") == 0 and len(r["data"]) == 4)
    r = call("POST", f"/instances/{zid}/pz-presets/apocalypse/apply", token=token)
    check("应用末日挑战", r.get("code") == 0, str(r)[:80])
    ini = os.path.join(DATA_ROOT, "instances", zid, "Server", "servertest.ini")
    check("servertest.ini 已建", os.path.exists(ini))
    text = read(ini)
    check("SandboxVars 落盘", "ZombieCount=4" in text and "FoodLoot=1" in text)
    r = call("POST", f"/instances/{zid}/pz-presets/builder/apply", token=token)
    check("切换建筑师", r.get("code") == 0)
    text2 = read(ini)
    check("预设值已更新", "ZombieCount=0" in text2 and "FoodLoot=4" in text2)
    r = call("POST", f"/instances/{zid}/pz-presets/no-such/apply", token=token)
    check("未知预设被拒", r.get("code") == 4702)
    cleanup(token, zid)

    print(f"\n{'=' * 40}\n四游戏矩阵：通过 {PASS}，失败 {FAIL}")
    for f in FAILURES:
        print("  -", f)
    sys.exit(1 if FAIL else 0)


if __name__ == "__main__":
    main()
