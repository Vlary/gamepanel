# ⛵ 游戏方舟 · GamePanel

**使用仓颉（Cangjie）语言从零实现的容器化游戏服务器管理面板。**

单二进制部署 · 无数据库依赖 · 中文界面 · 原创架构（非任何面板的复刻）

---

## 支持的游戏

| 游戏 | 镜像 | 存档快照 | Mod 管理 |
|---|---|---|---|
| ⛏ Minecraft（Paper/Forge/Fabric/原版） | itzg/minecraft-server | `world/` | mods/ + **Modrinth 一键装** |
| 🔥 饥荒联机版 DST（含洞穴） | jamesits/dst-server | `storage/` | mods/ |
| 🌳 泰拉瑞亚（TShock） | ryshe/terraria-tshock | 全目录 | ServerPlugins/ |
| 🧟 僵尸毁灭工程 PZ | renegademw/zomboid-dedicated-server | `Server/` | mods/ |

新游戏只需在 `src/games.cj` 加一个 `GameTemplate` 即可。

## 功能总览

**实例管理** — 一键创建（选游戏→版本→资源配额）· 启动/停止/重启/删除 · 内存/CPU 硬限制 · 随面板自启（`--restart unless-stopped`）· 实时状态与资源占用

**控制台** — 日志实时轮询 · 命令下发（Minecraft 走 RCON 同步回显，其余游戏走 stdin 控制台，容器以 `-i` 常开 stdin）· Minecraft 快捷命令栏（在线列表/存档/白名单）

**备份 / 快照（核心差异化）**
- 备份 = 整个数据目录 tar.gz，用于整体恢复与迁移
- 快照 = 仅游戏存档目录，体量小创建快，用于**世界级回档**（打完 Boss 掉了装备？回档重来）
- 一键恢复（要求实例停止；**恢复前自动创建保护快照**，恢复错档可再回）· 归档一键下载 · 保留策略（自动清理超额归档）
- 归档记录存相对路径，数据目录整体迁移后依然可用

**版本管理** — 每款游戏内置常用服务端版本，一键切换：拉新镜像→重建容器，数据目录始终保留

**Modrinth 整合包一键开服** — 创建向导里搜整合包（RLCraft/Create 等数万个）→选版本→面板自动下载 `.mrpack` 并装配全部内容：按清单声明设置加载器（Fabric/Forge/NeoForge/Quilt）与 MC 版本，逐文件下载服务端兼容的 Mod/配置（自动跳过纯客户端文件），完成后启动。真机验证：32 文件整合包装配 24 个、跳过 8 个客户端专属，voicechat 等 Mod 加载运行

**游戏专属配置（按游戏定制）** — 设置页直接改游戏配置文件，无需手动编辑：
- Minecraft：难度/模式/最大人数/视距/正版验证/白名单/PVP/MOTD（server.properties）
- 饥荒 DST：游戏模式/PVP/暂停/人数/服务器名/描述（cluster.ini）
- 泰拉瑞亚：槽位/预留位/进服密码/自动存档/备份间隔（TShock config.json）
- 僵尸毁灭工程：人数/密码/好友可见/公网列表（servertest.ini）
支持 properties/ini/json 三种格式，**逐行替换保留注释与顺序**；容器内 root 写的文件自动经 docker cp 落盘；改完提示重启生效

**Mod 管理（按游戏生态定制）**：
- **Minecraft** → Modrinth 市场：搜索自动按 MC 版本与加载器过滤（Paper→插件生态、Fabric/Forge→Mod 生态），选版本一键安装；本地 Mod 启用/禁用（.disabled 切换）
- **饥荒 DST / 僵尸毁灭工程** → Steam 创意工坊：按 Workshop ID 添加（自动写入 `dedicated_server_mods_setup.lua` / `servertest.ini` 的 `WorkshopItems+Mods`），服务器重启自动从 Steam 下载；一键跳转工坊搜索页
- **泰拉瑞亚** → 直链安装：粘贴 TShock 插件 .dll/.zip 直链下载进 ServerPlugins（zip 自动解压）

**文件管理器** — 目录浏览 · 在线编辑（≤2MB 文本）· 上传 · 下载 · 重命名 · 删除 · 新建目录，路径逃逸（`../`）全部拦截

**计划任务** — 五段 cron：定时备份/快照/重启/启停/发送控制台命令，`0 4 * * *`（每日 4 点）、`*/30 * * * *`（每半小时）等，创建时自动校验并计算下次运行时间，支持**立即执行一次**验证效果

**易用性** — 控制台命令历史（↑↓）· 文件管理支持 zip/tar.gz **在线解压**（整合包）· 总览页 10 秒自动刷新 + 实例搜索 · 移动端适配

**导入已有容器** — 把手工 `docker run` 起来的游戏服纳管进面板：读取镜像/端口/挂载/自启策略生成实例，**不重启不重建容器**；按镜像名自动识别游戏类型

**玩家管理（Minecraft）** — 在线玩家（踢出）· 白名单/OP/封禁列表可视化增删（经 RCON 由服务器权威维护）· 一键加白/设OP/封禁

**系统总览** — Docker 状态 · 实例统计 · 数据目录占用 · 磁盘余量

**资源监控** — 每实例每 30 秒采样 CPU%/内存，保留 1 小时历史，**metrics.json 持久化（面板重启不丢曲线）**，详情页 SVG 曲线（`GET /instances/{id}/metrics`）。列表接口直读采样缓存，**~30ms 响应**（不再同步等待 docker stats）；后台拉取镜像时状态显示"拉取镜像中…"

**异常告警** — 意外退出检测（区分用户主动操作）· Webhook 通知（`GP_NOTIFY_URL`，POST JSON）

**API 开放** — 面板自身就是 REST API + Bearer Token，可直接脚本化运维（见 `docs/API.md`）

## 快速开始

### 1. 环境准备

```bash
# 仓颉 SDK 1.1.3 + stdx 1.1.3.1 安装（一次性），见 scripts/setup-env.sh 头部注释
# 本机已装好的直接:
cd gamepanel
source scripts/setup-env.sh
cjpm build
```

### 2. 启动

```bash
GP_ADMIN_PASS=你的强密码 ./scripts/run.sh
# 打开 http://<主机IP>:8080
```

环境变量：

| 变量 | 默认 | 说明 |
|---|---|---|
| `GP_PORT` | 8080 | 监听端口 |
| `GP_ADMIN_PASS` | admin123 | **务必修改** |
| `GP_DATA` | `<项目>/data` | 实例数据/备份/快照根目录 |
| `GP_DOCKER` | docker | docker 命令路径 |
| `GP_WEB` | `<项目>/web` | 前端文件目录 |
| `GP_NOTIFY_URL` | 空 | 实例意外退出时的 Webhook（POST JSON） |

### 3. 面板操作建议

1. 登录 → 右上角「创建实例」
2. 选游戏 → 选版本 → 填名称（端口留空取默认，内存 2048MB 起步）
3. 饥荒需要在「自定义环境变量」填 `DST_CLUSTER_TOKEN=<你的令牌>`（[Klei 账户页](https://accounts.klei.com/account/game/servers)申请）
4. 实例卡片 → 「详情」进入控制台/文件/备份/快照/Mod/设置
5. 「计划任务」里配一个 `0 4 * * *` 每日快照，保留 7 份

## 目录结构

```
gamepanel/
├── cjpm.toml          # 仓颉工程配置
├── src/               # 后端（仓颉，单包扁平结构）
│   ├── main.cj        #   入口：装配路由/调度器/HTTP 服务
│   ├── router.cj      #   自研正则路由分发器（{参数} 路径 + 方法匹配）
│   ├── httputil.cj    #   JSON 工具与统一响应
│   ├── auth.cj        #   登录 + Bearer Token
│   ├── config.cj      #   环境变量配置 + 数据目录布局
│   ├── model.cj       #   Instance/TaskItem/BackupRec 及 JSON 互转
│   ├── store.cj       #   db.json 存储（互斥锁 + 临时文件原子写）
│   ├── games.cj       #   四款游戏模板（镜像/端口/存档路径/版本）
│   ├── dockercmd.cj   #   Docker CLI 封装 + 控制台管道
│   ├── instance.cj    #   实例生命周期 + REST
│   ├── backup.cj      #   备份/快照/恢复/保留策略 + REST
│   ├── sched.cj       #   cron 解析器 + 调度线程 + REST
│   ├── files.cj       #   文件管理器（路径安全） + REST
│   ├── mods.cj        #   Modrinth 集成 + Mod 管理 + REST
│   ├── sysinfo.cj     #   总览统计 + 静态资源服务
│   └── tests.cj       #   单元测试（cjpm test）
├── web/               # 前端（原生 HTML/CSS/JS，零依赖零构建）
├── data/              # 运行时数据（实例目录/备份/快照/db.json）
├── docs/              # 调研报告 / API 文档 / 部署指南
└── scripts/           # 环境初始化与启动脚本
```

## 设计理念（为什么这样写）

- **一切皆文件**：实例是"JSON 元数据 + 数据目录"，没有数据库；状态可 `cat data/db.json` 直接看，备份即拷目录
- **Docker CLI 而非 Engine API**：与运维权限模型一致（docker 组即可用）、不受 Docker 版本接口变更影响、问题可直接在宿主机复现
- **备份与快照分离**：调研发现云厂商只有磁盘级快照、开源面板只有全量备份（见 `docs/调研报告.md`），"世界级快照回档"是本面板的差异化定位
- **零依赖前端**：单 HTML + 单 JS + 单 CSS，无构建链、无 CDN、离线可用，符合"页面简洁、逻辑严谨易理解"

## 测试

```bash
cjpm test     # 11 个用例：cron 解析/命中/nextAfter、percentDecode、safeJoin 路径安全、JSON 往返、MIME
```

已在真实 Docker 环境（Docker 29.x）完成全链路验证：

- **Minecraft**：创建（自动拉镜像启动，healthy）→ RCON 命令 → 快照/备份/恢复（含恢复前保护快照）→ Modrinth 搜 Lithium 选 1.20.1 一键安装 → 文件在线编辑（含中文路径与 `../` 逃逸拦截）→ 计划任务
- **泰拉瑞亚**：创建 → **stdin 控制台完成交互式建世界全流程**（尺寸/名字/种子/难度菜单逐项发送）→ 服务器上线（TCP 7777）→ TShock `/playing` 命令 → 世界文件落宿主挂载目录 → 快照 1.1MB 含真实世界
- **监控与告警**：CPU/内存历史采样 → metrics 接口 → `docker kill` 模拟意外退出 → Webhook 收到 `{"event":"instance_exit",...}`（面板主动停止不误报）

## 权限与多节点

- **多用户三级角色**：viewer（只读）/ operator（日常运维）/ admin（全部+用户管理）。权限按 HTTP 方法自动分级（GET=viewer、写操作=operator、删除=admin），admin 专属操作二次校验；密码 salt+SHA256 哈希存储；操作审计日志（最近 200 条，用户管理页可视）
- **多节点**：基于 `docker context`——宿主机 `docker context create 节点名 --docker "host=ssh://user@远程机"` 后在面板登记，即可把实例开到远程机器（全部容器能力复用，创建向导选节点，列表显示节点徽标，节点有实例时禁止移除）
- **实时控制台**：WebSocket 长连接实时推送日志（`docker logs -f`），命令直接双向发送；断线自动回退 2.5s 轮询

## Roadmap（下一阶段）

- [ ] 实例级资源报表/日报推送
- [ ] CurseForge 生态接入（Mod/整合包）
- [ ] 配置文件语法高亮编辑器
