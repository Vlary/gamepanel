# 模块审计清单 — GamePanel（仓颉）

技术栈：Cangjie 1.1.3 + stdx（HTTP 服务）、Docker CLI、无数据库（JSON 文件存储）、原生 JS 前端
入口：`main.cj` 装配路由；HTTP 端口 GP_PORT(8080)；Bearer Token 认证；三级角色 viewer/operator/admin

| # | 模块 | 职责 | 风险 | 状态 |
|---|------|------|------|------|
| 1 | main.cj / router.cj / httputil.cj | 入口、路由分发、JSON 工具 | 高（入口/鉴权链） | 待审 |
| 2 | auth.cj / users.cj / store.cj | 登录、Token、用户管理、JSON 存储 | 高（认证授权） | 待审 |
| 3 | instance.cj / dockercmd.cj / games.cj / config.cj | 实例生命周期、Docker CLI 封装 | 高（命令注入） | 待审 |
| 4 | files.cj | 文件管理器 | 高（路径穿越/任意读写） | 待审 |
| 5 | backup.cj | 备份/快照/恢复 | 高（tar 解压/路径） | 待审 |
| 6 | mods.cj | Modrinth 集成、Mod 下载 | 高（SSRF/下载写文件） | 待审 |
| 7 | gamecfg.cj | 游戏配置文件改写 | 中（配置注入） | 待审 |
| 8 | sched.cj / ops.cj | cron 调度、控制台命令 | 高（命令注入/定时任务） | 待审 |
| 9 | importer.cj / nodes.cj | 容器导入、多节点 | 中（命令注入） | 待审 |
| 10 | monitor.cj / sysinfo.cj / players.cj / wsconsole.cj | 监控、总览、玩家、WebSocket | 中（WS 鉴权/信息泄露） | 待审 |
| 11 | model.cj / tests.cj | 数据模型、测试 | 低 | 待审 |
| 12 | web/（index.html, app.js, style.css） | 前端交互 | 中（XSS） | 待审 |
