# REST API 文档

Base URL: `http://<host>:8080/api/v1`

除 `POST /auth/login` 外，所有请求需携带 `Authorization: Bearer <token>`。

统一响应格式：成功 `{"code":0, "data":...}` 或 `{"code":0, "msg":"..."}`；失败 `{"code":非0, "msg":"错误说明"}`。

---

## 鉴权

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/auth/login` | body `{"password":"..."}` → `{"token":"..."}`（7 天有效） |
| POST | `/auth/logout` | 注销当前 token |

## 模板与总览

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/templates` | 四款游戏模板（版本列表/端口/存档路径/Mod 目录/提示） |
| GET | `/overview` | Docker 状态、实例统计、数据目录占用、磁盘余量 |
| GET | `/health` | 健康检查（无需登录） |

## 实例

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/instances` | 列表（含实时容器状态、CPU%、内存占用） |
| POST | `/instances` | 创建并后台启动。body：`game/version/name/port(可选)/memoryMB/cpus(可选)/autoStart(可选)/extraEnv{}` |
| GET | `/instances/{id}` | 详情 |
| PUT | `/instances/{id}` | 改设置（name/memoryMB/cpus/autoStart/extraEnv），自动重建容器 |
| POST | `/instances/{id}/start \| stop \| restart \| delete` | 生命周期（delete 含数据目录与备份） |
| POST | `/instances/{id}/backup` | 立即全量备份，body `{"name":"..."}` |
| POST | `/instances/{id}/snapshot` | 立即存档快照，body `{"name":"..."}` |
| POST | `/instances/{id}/command` | 控制台命令，body `{"cmd":"say hello"}` |
| POST | `/instances/{id}/change-version` | 切版本（数据保留），body `{"version":"paper-1.21"}` |
| GET | `/instances/{id}/logs?tail=200` | 容器日志尾部 |
| GET | `/instances/{id}/records?kind=backup\|snapshot\|all` | 备份/快照记录 |

## 归档（备份/快照记录）

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/records/{rid}/restore` | 恢复（要求实例已停止；快照仅替换存档目录） |
| DELETE | `/records/{rid}` | 删除归档文件与记录 |

## 文件管理

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/instances/{id}/files?path=<相对路径>` | 目录列表 `{"dirs":[],"files":[]}` |
| GET | `/instances/{id}/file?path=` | 读文本文件（≤2MB） |
| PUT | `/instances/{id}/file?path=` | 写文件（body 为原始内容；前端上传即用此接口） |
| GET | `/instances/{id}/download?path=` | 下载文件 |
| POST | `/instances/{id}/file-action` | body `{"action":"mkdir\|delete\|rename","path":"...","newName":"..."}` |

所有路径都经过规范化校验，逃逸出实例数据目录的请求返回 `code=4103 非法路径`。

## Mod 管理

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/instances/{id}/mods` | Mod 目录列表 |
| DELETE | `/instances/{id}/mods/{name}` | 删除 Mod 文件 |
| GET | `/modrinth/search?q=` | Modrinth 搜索（官方公开 API 转发） |
| GET | `/modrinth/versions?project=` | 项目版本列表 |
| POST | `/instances/{id}/mods/install` | 一键安装，body `{"projectId":"...","versionId":"..."}` |

## 计划任务

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/tasks` | 列表（含 nextRun） |
| POST | `/tasks` | 创建。body：`name/instanceId/cron/action/command/keepCount`。action ∈ backup\|snapshot\|start\|stop\|restart\|command |
| PUT | `/tasks/{id}` | 改 name/enabled/cron/command/keepCount |
| DELETE | `/tasks/{id}` | 删除 |

cron 为五段表达式「分 时 日 月 周」，支持 `*`、`*/n`、`a-b`、`a,b,c`；日与周同时受限时按"同时满足"处理。

## 联机组网（EasyTier）

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/easytier/status` | 组网状态：config（密钥打码）/peers/routes/**events（上下线事件，倒序）**/**traffic（每节点累计流量）** |
| PUT | `/easytier/config` | 配置并启动（admin）。body：`mode(host\|join)/networkName/secret/peers[]/rpcPort/wgEnabled/peerNotify` |
| POST | `/easytier/stop` | 停止组网（admin） |
| GET | `/easytier/invite` | 玩家邀请卡：网络名/密钥/地址/一键命令（admin） |
| GET | `/easytier/wg-config` | WireGuard 客户端配置文本（admin，需开启 wgEnabled） |

后台每 30 秒采样 peer 表：节点上下线产生 `events` 记录（环形 200 条，`et-stats.json` 持久化），rx/tx 计数器增量累计入 `traffic`（对端重连计数器回退自动续算）。`peerNotify: true` 时上下线经 `GP_NOTIFY_URL` 推送 `peer_join`/`peer_leave`。

## 诊断与运维（admin）

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/health-report` | 一键健康自检 7 项（Docker/磁盘/端口冲突/容器/目录可写/TUN/任务） |
| GET | `/storage` | 数据目录明细（按实例 du 占用 + 备份/快照/监控分类） |
| GET | `/port-check?port=` | 端口预检：实例对比 + /proc 系统级 LISTEN |
| GET | `/cron-preview?expr=` | cron 校验 + 未来 5 次执行时间 |

## 安全与会话

| 方法 | 路径 | 说明 |
|---|---|---|
| POST | `/auth/change-password` | 自助改密。body：`oldPassword/newPassword`（新密码 ≥8 位） |
| GET | `/sessions` | 在线会话列表（token 打码前 8 位 + 用户/角色/过期，admin） |
| DELETE | `/sessions/{prefix}` | 踢出会话（按 token 前 8 位，admin） |

登录失败限速：同用户名 5 次失败锁定 15 分钟（code 1002，msg 含剩余时间）。

## 按游戏定制接口

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/instances/{id}/worlds` | MC 世界列表 + EULA 状态 |
| POST | `/instances/{id}/worlds/{name}/reset` | MC 单世界重置（admin，需停止，自动保护备份） |
| GET | `/instances/{id}/dst-shards` | DST 分片列表 + 世界预设列表 |
| POST | `/instances/{id}/dst-shards/{name}/toggle` | DST 分片启停（admin，需停止；Master 不可停） |
| POST | `/instances/{id}/dst-shards/{name}/worldgen` | DST 世界生成预设写入（body：preset） |
| GET | `/instances/{id}/terraria-worlds` | 泰拉瑞亚 .wld 世界列表 |
| POST | `/instances/{id}/terraria-worlds/select` | 切换当前世界（admin，body：file） |
| GET | `/instances/{id}/pz-presets` | PZ 沙盒预设列表 |
| POST | `/instances/{id}/pz-presets/{key}/apply` | 应用沙盒预设（admin） |

game-config 接口的字段现含 group（分组渲染）；实例列表/详情新增 ready 字段（游戏就绪检测）。

## 通知中心

| 方法 | 路径 | 说明 |
|---|---|---|
| GET | `/notifications` | 列表（倒序）+ 未读数；事件源：实例意外退出/任务失败/组网玩家动态 |
| POST | `/notifications/read-all` | 全部标记已读 |
| POST | `/notifications/clear` | 清空通知 |

任务对象新增 `history`（执行记录，环形 20 条）；实例记录接口新增 `GET /records/{rid}/preview`（归档文件清单，前 300 条）。

## 错误码段

| 段 | 含义 |
|---|---|
| 1001 | 密码错误 / 401 未登录 |
| 2001-2xxx | 实例创建/版本参数 |
| 3001-3xxx | 容器操作 |
| 4001-4xxx | 备份/文件 |
| 5001-5xxx | 计划任务 |

## 示例：脚本化每日备份

```bash
TOKEN=$(curl -s -X POST http://127.0.0.1:8080/api/v1/auth/login \
  -H 'Content-Type: application/json' -d '{"password":"xxx"}' | jq -r .data.token)
curl -s -X POST http://127.0.0.1:8080/api/v1/instances/gp-123/backup \
  -H "Authorization: Bearer $TOKEN" -H 'Content-Type: application/json' \
  -d '{"name":"cron-outside"}'
```
