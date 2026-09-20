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
