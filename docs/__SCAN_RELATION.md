# 服务端与扫描端（ScopeSentry-Scan）的关系

本文说明本仓库（服务端 / 主控）与 [`ScopeSentry-Scan`](https://github.com/Autumn-27/ScopeSentry-Scan)（扫描端 / 节点）的分工与对接方式。本仓库自身的目录结构与代码分层见 [__ARCHITECTURE.md](./__ARCHITECTURE.md)。

## 1. 结论速览

两者是**同一产品的两端程序**，不是代码依赖关系（Go module 之间无引用）：

- **本仓库 `ScopeSentry`** = 服务端 / 主控：Web 界面（Vue 打包后内嵌进二进制）、Gin API、任务编排与调度、资产管理、插件宿主、MCP 服务。
- **`ScopeSentry-Scan`** = 扫描端 / 节点：独立 Go 程序（`cmd/` + `internal/` + `modules/` + `libs/`），负责实际执行全部扫描阶段。
- 两端**共享同一套 MongoDB 与 Redis**，通过 Redis 队列/频道下发任务与回传日志，通过 MongoDB 共享扫描结果。

## 2. 仓库矩阵

| 仓库 | 角色 | 主要内容 |
| --- | --- | --- |
| `ScopeSentry`（本仓库） | 服务端、主控 | `cmd/main`（入口 + 内嵌前端）、`internal`（API / 服务 / 仓储 / 调度 / 插件）、`frontend`（Vue 3 源码） |
| [`ScopeSentry-Scan`](https://github.com/Autumn-27/ScopeSentry-Scan) | 扫描端、节点 | `cmd/ScopeSentry`、`internal`、`modules`（扫描模块）、`libs`、`pkg`；GoReleaser 交叉编译 + Docker 分发 |
| [`ScopeSentry-UI`](https://github.com/Autumn-27/ScopeSentry-UI) | 前端源码（历史独立仓） | 现已在 `frontend/` 内维护 |
| [`ScopeSentry-Plugin-Template`](https://github.com/Autumn-27/ScopeSentry-Plugin-Template) | 插件模板 | 与本仓库 `plugin-template/` 对应 |
| 插件市场 | 插件分发 | `https://plugin.scope-sentry.top` |

README 中并列给出了这些地址：

```25:27:README_CN.md
- 扫描端源码：[https://github.com/Autumn-27/ScopeSentry-Scan](https://github.com/Autumn-27/ScopeSentry-Scan)
- 前端源码：[https://github.com/Autumn-27/ScopeSentry-UI](https://github.com/Autumn-27/ScopeSentry-UI)
- 插件市场: [插件市场](https://plugin.scope-sentry.top/)
```

前端「关于」页与仪表盘的节点升级表单同样指向扫描端发布包（`ScopeSentry-Scan_linux_amd64_vx.x.x.zip`）。

## 3. 部署形态

`single-host-deployment.yml` 中，扫描端作为独立容器与服务端同栈部署：

```78:82:single-host-deployment.yml
  scopesentry-scan:
    image: autumn27/scopesentry-scan:latest
    network_mode: host
    container_name: scopesentry-scan
    restart: always
```

启动后共四个容器：`scope-sentry`（服务端 + Web 界面）、`scopesentry-scan`（扫描节点）、MongoDB、Redis，默认自带一个扫描节点。

**新增节点**（横向扩展）：克隆 `ScopeSentry-Scan`，在 `build/` 下编辑 `.env` 中的 MongoDB / Redis 连接信息与 `NodeName`（每个节点必须唯一，留空则随机生成，可在 Web 界面改名），再启动 `scan-docker-compose.yml`。

## 4. 对接通道（Redis 键与频道约定）

服务端侧可验证的对接点，均为 Redis 约定：

| 用途 | Key / 通道 | 数据形态 | 服务端代码位置 |
| --- | --- | --- | --- |
| 任务下发 | `NodeTask:<节点名>` | List，元素为 `ScanTemplate` JSON | `internal/repositories/task/task/task.go` `RPushNodeTask` |
| 节点注册与心跳 | `node:<节点名>` | Hash：`state`、`updateTime`、`running`、`finished`、`cpuNum`、`memNum`、`maxTaskNum`、`version`、`modulesConfig` | `internal/repositories/node/node.go` `GetAllNodes` |
| 节点日志 | Pub/Sub 频道 `logs` | `{"name": "<节点名>", "log": "<内容>"}` | `internal/services/redis_log_subscriber/log_subscriber.go` |
| 日志缓存 | `log:<节点名>` | List，按 `log.totalLogs` 截断 | 同上 |
| 上线补推 | 节点输出 `Register Success` → 服务端补推未完成任务 | 业务约定 | `log_subscriber.go` `checkNodeTask` |
| 任务结束触发 | 节点输出 `Task end` → 刷新进度与项目资产关联 | 业务约定 | `log_subscriber.go` |
| 进度统计 | `TaskInfo:tmp:<taskId>`（Set）、`TaskInfo:time:<taskId>` | 扫描端写入，服务端 `SCARD` 计算百分比 | `internal/services/task/task/task.go` `ProcessTaskProgress` |
| 阶段时间线 | `TaskInfo` Hash 字段 `<阶段>_start` / `<阶段>_end`、`scan_start` / `scan_end`、`node` | Hash | `task.go` `populateProgressFromRedis` |
| 配置刷新 / 重启 / 升级 | `refresh_config:<节点名>` | List，元素为 `{"name","type","content"}`，`type` 含 `restart` | `internal/repositories/node/node.go` `RefreshConfig`、`internal/services/node/service.go` `RestartNode` |
| 节点插件状态 | `NodePlg:<节点名>` | Hash 字段 `<hash>_install`、`<hash>_check` | `internal/repositories/node/node.go` `GetNodePlugin` |
| 版本对照 | `version.json` 的 `scan` 字段 vs 节点上报的 `node:<name>.version` | HTTP 拉取 + Redis 读取 | `internal/api/handlers/system/system.go` |

**MongoDB 是共享数据库**：扫描端把结果直接写入 `asset`、`IPAssetTmp`、`vulnerability`、`HttpBody` 等集合；服务端不执行扫描，只消费与展示，例如 `internal/worker/ip_asset.go` 批量读取 `IPAssetTmp` 聚合为 `IPAsset`。

## 5. 端到端数据流

```
① 用户创建任务（Web）
   → 服务端 services/task/common.Insert        写入 task 集合
   → CreateTaskScan 生成 ScanTemplate（14 个扫描阶段参数）
   → 选择节点 → RPush  Redis List: NodeTask:<节点名>

② 扫描节点消费
   → BRPOP NodeTask:<节点名>
   → 执行 TargetHandler → SubdomainScan → SubdomainSecurity
     → PortScanPreparation → PortScan → PortFingerprint
     → AssetMapping → AssetHandle → URLScan → WebCrawler
     → URLSecurity → DirScan → VulnerabilityScan → PassiveScan
   → 结果直接写 MongoDB（asset / IPAssetTmp / vulnerability / HttpBody ...）
   → 进度写 Redis：TaskInfo:tmp:<taskId>、TaskInfo:time:<taskId>
   → 日志 PUBLISH 到 Redis 频道 logs
   → 节点心跳持续更新 Redis Hash: node:<节点名>

③ 服务端侧闭环
   → services/redis_log_subscriber 消费 logs
   → 遇到 Task end 触发 TaskProgress（按 SCARD 计算进度、置 status=3）
   → 触发服务端插件 RunTaskEnd
   → projectService.RefreshProjectAssociations 回填项目资产关联与 AssetCount
   → worker 异步聚合 IP 资产、图标、截图
```

## 6. 职责边界

### 服务端（本仓库）负责

- 目标与项目管理、任务创建、周期任务调度（gocron，`scan` / `page_monitoring` / `server_plugin` 三类 job）
- 扫描模板与阶段参数下发、节点选择与状态展示
- 用户 / 角色 / 权限 / API Key、资产查询与统计、导出
- 插件管理（导入、校验、分发、卸载、重装）与**服务端插件执行**（`plugins.type == "server"`，yaegi 解释执行）
- MCP 服务（`/mcp`，把资产与任务能力暴露给 AI 客户端）
- Swagger 文档与内嵌前端资源托管

### 扫描端（`ScopeSentry-Scan`）负责

- 全部实际探测执行：子域枚举、端口扫描、指纹识别、资产测绘、URL 采集、爬虫、目录扫描、漏洞扫描、被动扫描等 14 个阶段
- 结果直接落库 MongoDB，进度与日志写 Redis
- 节点心跳与配置刷新响应（重启、参数热更新）
- **扫描端插件**的安装、校验与执行（`plugins` 集合中非 `server` 类型，状态回报 `NodePlg:<节点名>`）

> `internal/mcp/tools.go` 中也明确跳过 `type == "server"` 的插件，说明服务端插件不参与扫描流水线。

## 7. 版本与兼容性

`version.json` 同时维护两端版本：

```json
{
  "server": "1.9.4",
  "scan": "1.9.1",
  "server_msg": "https://www.scope-sentry.top/guide/update/",
  "scan_msg": "https://www.scope-sentry.top/guide/update/"
}
```

- 服务端当前版本取自编译期变量 `constants.Version`；节点版本由节点上报到 `node:<name>` 的 `version` 字段。
- `/api/system/version` 会分别用 `server` 与 `scan` 字段判断「是否有新版本」，因此两端**独立发版、需配套使用**，跨大版本混用不保证协议兼容。

## 8. 排查要点

| 现象 | 优先检查 |
| --- | --- |
| 任务创建后节点不执行 | `NodeTask:<节点名>` 是否堆积（节点名大小写/拼写是否与服务端选择一致） |
| 节点在界面显示离线 | `node:<节点名>` 的 `updateTime` 是否超过 300 秒（`NodeTimeout`），`state` 是否为 `1` |
| 有资产但进度不动 | `TaskInfo:tmp:<taskId>` 是否存在、`task.taskNum` 是否为 0 |
| 界面看不到节点日志 | 频道 `logs` 是否有消息、Redis `log:<节点名>` 是否被 `log.totalLogs` 截断 |
| 插件在节点上未生效 | `NodePlg:<节点名>` 中 `<hash>_install` / `<hash>_check` 是否为 `1`，以及 `plugins.type` 是否误设为 `server` |
| 任务结束但项目资产为空 | `projectService.RefreshProjectAssociations` 是否执行（依赖 `Task end` 日志触发） |
