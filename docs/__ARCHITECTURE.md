# ScopeSentry 工程架构

面向开发者的仓库结构与目录说明。ScopeSentry 是一个资产发现与漏洞扫描平台：Go 后端（Gin）提供 API、任务调度与插件运行时，Vue 3 前端经 Vite 打包后内嵌进二进制，扫描节点作为独立 Agent 通过 Redis 与主控通信。

## 1. 技术栈

| 层次 | 技术 |
| --- | --- |
| 后端语言 | Go 1.24（模块 `github.com/Autumn-27/ScopeSentry`） |
| HTTP 框架 | Gin + swaggo（Swagger 文档） |
| 存储 | MongoDB（业务数据 + GridFS 文件）、Redis（任务队列 / 日志频道 / 缓存） |
| 调度 | gocron（全局定时任务，支持 cron 与固定间隔） |
| 插件运行时 | traefik/yaegi（Go 源码解释执行，热加载，无需编译） |
| AI 集成 | modelcontextprotocol/go-sdk（`/mcp` Streamable HTTP） |
| 前端 | Vue 3 + TypeScript + Vite + Element Plus + UnoCSS + ECharts，基座为 vue-element-plus-admin |

## 2. 顶层目录总览

```
ScopeSentry/
├── cmd/main/                  进程入口：main.go + 内嵌前端产物 static/
├── internal/                  Go 后端全部业务代码（20 个一级包）
├── pkg/response/              对外可复用的响应封装
├── frontend/                  Vue 3 前端源码工程
├── interface/                 Swagger 接口文档包（package apidocs）
├── docs/                      文档与资源：架构文档、流程图、文档配图
├── plugin-template/           插件编写示例（单文件 + 目录式）
├── uploads/                   运行时上传目录（图片等）
├── dockerfile                 容器镜像构建文件
├── single-host-deployment.yml 单机 docker compose 部署（mongo 7.0.28）
├── single-host-deployment-fix.yml  同上，mongo 版本回退为 7.0.4 的兼容变体
├── version.json               服务端与扫描端版本号及更新说明地址
├── go.mod / go.sum            Go 依赖
└── README.md / README_CN.md   项目说明（英文 / 中文）
```

`interface/` 与 `docs/` 目录内容：

```
interface/
├── docs.go                    swag 生成产物：docTemplate + SwaggerInfo
├── swagger.go                 全局 API 注解（版本与描述、host、BasePath、tag 说明）
└── swagger.json / .yaml       同一份文档的静态导出，供外部工具导入

docs/
├── __ARCHITECTURE.md          本文档：仓库结构与目录说明
├── __SCAN_RELATION.md         服务端与扫描端（ScopeSentry-Scan）的关系
├── SKILL.md                   MCP 使用指南（面向已部署实例的用户）
├── 流程图.svg                 整体工作流程图
└── images/                    README 与文档配图
```

> `interface/` 目录名沿用 Go 关键字的字面名称，因此包名取 `apidocs`，导入路径为 `github.com/Autumn-27/ScopeSentry/interface`。修改注解后重新生成：
>
> ```bash
> swag init -g cmd/main/main.go -o interface --packageName apidocs
> ```

> 扫描端（节点）为独立仓库 `ScopeSentry-Scan`，通过 Redis 队列与 MongoDB 与本工程对接，详见 [__SCAN_RELATION.md](./__SCAN_RELATION.md)。

## 3. 进程入口 `cmd/main/`

| 文件 | 作用 |
| --- | --- |
| `cmd/main/main.go` | `package main`。按序执行：配置初始化 → MongoDB/Redis 连接（`_` 匿名导入触发 `init`）→ `update.Update()` 版本迁移 → `bootstrap.GetProjectList()` 载入项目缓存 → `scheduler.InitializeGlobalScheduler()` → goroutine 订阅 Redis 日志频道 → `routes.SetupRouter()` → `mcp.RegisterRoutes()` → 注册静态资源与 SPA 兜底路由 → `worker.Run()` 启动后台消费者 → 监听 HTTP（默认 8082）→ 捕获信号优雅关闭。文件顶部含 swaggo 全局注解，`//go:embed static/*` 内嵌前端产物。 |
| `cmd/main/basic_usage.go` | 内嵌静态资源（`assets`/`css`/`js`/`lib`/`plugins`/`png`/`draco`）的注册辅助逻辑、`/map`、`/favicon.ico` 与 SPA `NoRoute` 兜底处理。 |
| `cmd/main/static/` | 前端构建产物（`frontend` 执行 `build:pro` 后输出），随二进制分发，`dist/` 之外无需单独部署前端。 |

> 扫描节点（Scanner）为独立仓库/独立二进制，不在本工程内，通过 Redis 列表消费任务。

## 4. 后端分层

依赖方向严格单向：

```
api/routes → api/handlers → services → repositories → database/{mongodb,redis}
                                  ↑
                              options（依赖注入，唯一自下而上的装配点）
```

`models`、`config`、`logger`、`utils`、`constants` 为全层共享的基础设施。

### 4.1 `internal/api/` — 接口层

| 子目录 | 作用 |
| --- | --- |
| `routes/` | 声明式路由。`routes.go` 的 `SetupRouter()` 在 `/api` 下装配全部子路由；按业务域分为 `assets`（含 app/asset/crawler/dirscan/ip/mp/page_monitoring/root_domain/sensitive/statistics/subdomain/url/vulnerability 13 组）、`task`（含 `scheduler.go`、`template.go` 子路由）、`project`、`poc`、`export`、`plugin`、`dictionary`、`fingerprint`、`node`、`role`、`system`、`user`、`configuration`、`sensitive_rule`、`apikey`。 |
| `routes/common/` | `register.go` 为路由注册引擎（递归把 `models.RouteGroup` 转成 gin 路由）；`permission.go` 提供 `WithAuth()` 权限中间件包装。 |
| `handlers/` | 各业务域处理器，共 15 个目录。核心：`task/task.go`（任务增删改查、启动/停止/重测/进度）、`plugin/plugin.go`（插件列表、保存、导入、重装、日志、远程搜索）、`assets/asset/asset.go` 与 `assets/statistics/statistics.go`（资产查询与统计）。 |
| `middleware/` | `auth.go`（JWT）、`apikey.go`、`permission.go`（RBAC）、`cors.go`、`i18n.go`、`logger.go`。 |
| `response/` | 内部统一的 JSON 响应结构与错误码（与 `pkg/response` 职责相近，服务内部使用）。 |
| `models/route.go`（见第 5 节） | `RouteGroup` / `Route` 路由声明模型。 |

### 4.2 `internal/services/` — 业务逻辑层

| 子目录 | 作用 |
| --- | --- |
| `task/common/` | 任务编排核心。`Insert()` 建任务并异步 `CreateTaskScan()` 生成扫描模板，选节点后逐条下发；`GetScanTemplate`、`ParameterParser`。 |
| `task/task/` | 任务生命周期：列表、详情、删除、启动、停止、重测、进度汇总。 |
| `task/template/` | 扫描模板 CRUD 与参数解析。 |
| `task/scheduler/` | 周期任务（`ScheduledTasks`）业务服务。 |
| `plugin/` | 插件管理中枢：导入、校验、安装、运行、日志、状态落库；`scheduler.go` 把插件周期挂到全局调度器；`utils.go` 源码哈希与模板校验。 |
| `redis_log_subscriber/` | 订阅 Redis 日志/结果频道，消费节点回传的扫描日志与资产结果，回写任务进度。 |
| `assets/` | 14 个资产域业务包（asset/ip/subdomain/url/root_domain/app/mp/crawler/dirscan/sensitive/vulnerability/statistics/page_monitoring/common），`common/common.go` 为资产公共查询、去重、过滤核心。 |
| `node/service.go` | 节点在线状态判定与配置下发。 |
| 其余 | `project`、`user`、`poc`、`fingerprint`、`configuration`、`dictionary`、`sensitive_rule`、`export`、`apikey`、`common`、`system`、`role`。 |

### 4.3 `internal/repositories/` — 数据访问层

| 子目录 | 作用 |
| --- | --- |
| `common/common.go` | 通用仓储，封装 Mongo 的 Find/Insert/Update/Aggregate 与 Redis 的 Get/Set/HSet/SAdd 等，被大量 service 复用。 |
| `task/task/task.go` | 任务仓储，其中 `RPushNodeTask` 把扫描任务序列化后推入 Redis 列表 `NodeTask:<节点名>` 下发给节点。 |
| `task/template/template.go` / `task/scheduler/scheduler.go` | 扫描模板仓储 / 周期任务仓储（`scheduled` 集合）。 |
| `assets/*` | 各资产表（asset/ip/subdomain/url/root_domain/app/mp/crawler/dirscan/sensitive/vulnerability/statistics/page_monitoring/taker）的查询与聚合。 |
| 其余 | `project`、`user`、`role`、`node`、`plugin`、`poc`、`fingerprint`、`dictionary`、`sensitive_rule`、`export`、`apikey`。 |

### 4.4 `internal/database/` — 存储连接

| 文件 | 作用 |
| --- | --- |
| `mongodb/mongodb.go` | `init` 中连接 MongoDB，暴露全局 `Client` / `DB`。 |
| `mongodb/initdb.go` | 首次启动建库、建集合、建索引并写入默认数据。 |
| `mongodb/gridfs.go` | GridFS 文件存储（截图、图标等）。 |
| `redis/redis.go` | `init` 中连接 Redis，暴露全局 `Client`。 |

### 4.5 其余后端包

| 包 | 作用 |
| --- | --- |
| `bootstrap/` | 启动事件框架与启动期数据装载。`initdata.go` 的 `GetProjectList()` 把 project 集合读入内存 `ProjectList` map 供全局使用；`bootstrap .go`（文件名含空格，历史命名）注册 Banner、建库、通知配置等启动事件。 |
| `config/` | viper 加载配置：读取**可执行文件同目录的 `config.yaml`**，文件不存在则自动生成默认配置；支持 `MONGODB_IP`、`REDIS_IP`、`TIMEZONE` 等环境变量覆盖；全局单例 `config.GlobalConfig`；负责 `PLUGINKEY` 的生成与读取。`notification.go` 保存通知接口全局变量。根目录 `.env` 仅供部署脚本使用，Go 侧不读取。 |
| `constants/` | `defaults.go` 用 `go:embed` 内嵌目录字典、域名字典、敏感规则 JSON、端口字典（top100/top1000/all）及版本号变量；`permissions.go` 为 RBAC 权限点常量表。 |
| `global/` | 全局单例（`logger.go`），与 `logger` 包并存，属历史遗留。 |
| `i18n/` | 内嵌 `locales/*.json`，提供 `Translate(locale, messageID)`。 |
| `interfaces/` | `plugin.go` 定义插件契约 `Plugin`：`GetName` / `Cycle` / `Install` / `Execute` / `TaskEnd` / `Clone` / `Log` / `GetPluginId`。 |
| `logger/` | zap 初始化、分级输出与滚动；`gin.go` 提供 Gin 请求日志与 Recovery 中间件。 |
| `mcp/` | MCP 服务端：`register.go` 注册 `/mcp`（API Key 保护）、`server.go` 构造 Server、`tools.go` 把资产/任务能力暴露为 AI 工具、`schema.go` 定义工具入参 JSON Schema。 |
| `models/` | 全部 BSON 结构与 DTO（32 个文件）。`template.go` 定义 `ScanTemplate` 与 `Parameters`，即扫描阶段清单：TargetHandler → SubdomainScan → SubdomainSecurity → PortScanPreparation → PortScan → PortFingerprint → AssetMapping → AssetHandle → URLScan → WebCrawler → URLSecurity → DirScan → VulnerabilityScan → PassiveScan。`asset.go`/`field.go`/`search.go`/`statistics.go` 为资产通用模型、字段元数据、检索表达式与统计。 |
| `options/` | `plugin.go` 的 `PluginOption` 是有意为之的“反向依赖”：为插件注入 DB、Redis、TaskCommonService、TemplateService、PocService、AssetCommonService、CommonRepo、Node、日志/通知/变量存取等运行时能力，`NewOption(hash)` 构造。 |
| `plugins/` | 插件运行时。`init` 时 `InstallPlugin()` 从 Mongo `plugins` 集合（`type=server`）取源码，经 yaegi 解释器 `LoadPlugin(code, hash)` 抽取 `GetName/Execute/TaskEnd/Cycle/Install`；`custom_plugin.go` 实现 `interfaces.Plugin`，`Log()` 同时写 zap 与 Redis `logs:server_plugins:<hash>`；`utils.go` 提供 `RunPluginOnce` 与插件变量存取。 |
| `scheduler/` | 全局 gocron 调度器。`scheduler.go` 注册三类 handler：`scan`、`page_monitoring`、`server_plugin`；Job 持久化在 Mongo `scheduled` 集合。`jobs/scan.go` 生成周期扫描任务，`jobs/page_monitoring.go` 创建页面监控任务，`jobs/server_plugin.go` 执行服务端插件。 |
| `symbols/` | yaegi 符号表。`symbols.go` 通过 `go:generate yaegi extract` 列出插件可引用的符号，其余 `github_com-Autumn-27-ScopeSentry-*` / `go_mongodb_org-*` 文件为 reflection 生成产物。 |
| `update/` | 版本升级与数据迁移。`update.go` 读取 `config` 集合中的 version 记录，按 semver 依次执行 `update18.go` / `update19.go` / `update20.go`。 |
| `utils/` | `helper/`（HTTP 请求、检索表达式解析、FOFA/Shodan 查询、缓存、任务辅助、时间格式化）、`ct/`（证书透明日志监控 SDK：sdk/watcher/matcher/parser/checkpoint）、`random/`，以及 `requests.go`、`filetool.go`、`context_manager.go`、`tools.go`（YAML 封装等）。 |
| `worker/` | 后台常驻消费者。`start.go` 的 `Run()` 启动多个 goroutine：`ip_asset.go` 从 `IPAssetTmp` 批量聚合端口/域名/项目，`iconhandle.go` 处理 favicon，`screenshot.go` 处理站点截图。 |

## 5. 关键数据流

### 5.1 任务执行主链路

```
API AddTask
  → services/task/common.Insert            写 task 集合
  → CreateTaskScan（异步）                 生成 ScanTemplate（14 个扫描阶段）
  → GetScanTemplate → services/node 选节点
  → repositories/task/task.RPushNodeTask   Redis List: NodeTask:<节点名>
  → 扫描节点（独立进程）消费任务
  → 节点回传日志/资产到 Redis 频道
  → services/redis_log_subscriber 订阅解析
  → services/task/task.TaskProgress       更新进度
  → services/assets/*                     资产入库
  → worker/*                              异步聚合 IP 资产、图标、截图
```

### 5.2 定时调度链路

- 扫描周期任务：`InitializeGlobalScheduler()` → gocron 加载 `scheduled` 集合 → `scheduler/jobs/scan.go` → `services/task/common.Insert`（回到主链路）。
- 插件周期任务：`services/plugin/scheduler.AddJob` → `scheduler.GetGlobalScheduler().AddJob` → `scheduler/jobs/server_plugin.go` → 插件执行。
- 页面监控：`scheduler/jobs/page_monitoring.go` 周期创建监控任务。

### 5.3 插件链路

```
Web 上传源码 POST /api/plugin/import
  → services/plugin 校验并写入 Mongo plugins（hash/source/type=server/status）
  → 进程启动 plugins.init() → InstallPlugin()
  → yaegi LoadPlugin(code, hash) + symbols.Symbols
  → custom_plugin.Plugin 实现 interfaces.Plugin
  → Execute(options.PluginOption) 调用注入的 Task/Template/Poc/AssetCommon/Node 服务与 CommonRepo
```

插件是可热加载的 Go 源码，非编译产物；可引用的包受 `internal/symbols` 限制（标准库、`os/exec`、`gopkg.in/yaml.v3`，以及经 `yaegi extract` 的内部包：models/options/utils/ct 与 bson/mongo）。

### 5.4 MCP 链路

`cmd/main` → `mcp.RegisterRoutes(router)` → `newServer()` → `registerTools`，工具内部复用 services/repositories，供 AI 客户端通过 `/mcp` 操作平台。

## 6. 前端工程 `frontend/`

基座为 vue-element-plus-admin，包名 `vue-element-plus-admin`。构建脚本使用 pnpm。

### 6.1 根级文件

| 文件 | 作用 |
| --- | --- |
| `vite.config.ts` | Vite 构建配置（代理、别名、打包输出）。 |
| `uno.config.ts` | UnoCSS 原子化样式配置。 |
| `tsconfig.json` / `plopfile.js` / `plop/` | TypeScript 配置与 plop 模板生成器。 |
| `.env.base` / `.env.dev` / `.env.test` / `.env.pro` / `.env.gitee` | 各环境变量与 API 前缀。 |
| `.eslintrc.js` / `prettier.config.js` / `stylelint.config.js` / `commitlint.config.js` | 代码与提交规范。 |
| `scripts/` / `public/` / `mock/` / `types/` | 构建脚本（含图标生成）、静态公共资源、Mock、全局类型声明。 |

### 6.2 `frontend/src/`

| 目录/文件 | 作用 |
| --- | --- |
| `main.ts` | 应用入口：挂载 Vue、注册 Element Plus、UnoCSS、ECharts、i18n、SVG 图标等插件。 |
| `App.vue` | 根组件。 |
| `permission.ts` | 全局路由守卫：登录态校验、动态菜单/路由注入、权限判定。 |
| `api/` | 按业务域划分的请求模块，每个目录含 `index.ts`（+ `types.ts`）：`apikey`、`asset`、`common`、`Configuration`、`dashboard`（含 `analysis`）、`department`、`DictionaryManagement`、`export`、`Fingerprint`、`login`、`menu`、`node`、`plugins`、`poc`、`project`、`ProjectAggregation`、`request`、`role`、`scommon`、`sensitive`、`table`、`task`、`vul`。 |
| `axios/` | axios 实例与拦截器（token 注入、错误提示、刷新）。 |
| `router/index.ts` | 路由表与动态路由装配。 |
| `store/` | Pinia 仓库：`app.ts`、`locale.ts`、`lock.ts`、`permission.ts`、`tagsView.ts`、`user.ts`。 |
| `layout/` | 主框架布局（侧边栏、顶栏、标签页等 `components/`）。 |
| `views/` | 页面：`Dashboard`、`Task`（`Task.vue`、`ScanTemplate.vue`、`ScheduledTask.vue`）、`Asset`（`detail/`、`search/`、`export/`、`components/`）、`Project`（`detail/`）、`Node`、`Plugins`、`Poc`、`Fingerprint`、`Sensitive`、`DictionaryManagement`、`Configuration`、`Setting`、`Login`、`Redirect`、`Error`、`Components`（通用示例页）。 |
| `components/` | 40+ 通用组件：`Table`、`Form`、`Dialog`、`Echart`、`Editor`（CodeMirror）、`JsonEditor`、`Search`、`Menu`、`TagsView`、`Permission`、`Icon`/`IconPicker`、`ImageViewer`、`Qrcode`、`VideoPlayer`、`Waterfall` 等，均按 `组件名/src/*.vue` + `index.ts` 组织。 |
| `hooks/` | `web/`（DOM、剪贴板、水印等）、`event/`（事件总线）。 |
| `directives/` | `permission/` 权限指令（`v-hasPermi` 等）。 |
| `plugins/` | 第三方集成：`elementPlus`、`unocss`、`echarts`、`vueI18n`、`svgIcon`、`animate.css`。 |
| `locales/` | i18n 词条（中/英），对应后端 `internal/i18n`。 |
| `styles/` | 全局样式与主题变量。 |
| `constants/` | 前端枚举与常量。 |
| `utils/` | 工具函数（鉴权、格式化、树结构等）。 |
| `assets/` | 图片、SVG、二维码等静态资源。 |

## 7. 插件示例 `plugin-template/`

| 路径 | 说明 |
| --- | --- |
| `plugin-template/nuclei_monitor.go` | 单文件插件示例：拉取/监听 nuclei 模板变更并推送通知，展示 `GetName()` 等入口写法（`package plugin`）。 |
| `plugin-template/ct_monitor/ct_monitor.go` | 目录式插件示例：证书透明日志监控，展示多文件组织、`Cycle()` 返回 cron、`Install()`、`Execute(op options.PluginOption)`、`TaskEnd()`，并调用 `internal/utils/ct` SDK。 |

## 8. 配置与部署

| 文件 | 说明 |
| --- | --- |
| `config.yaml`（运行期生成） | 位于可执行文件同目录，首次启动由 `internal/config` 自动生成；含 server（端口/模式）、system（时区/图片目录/插件密钥）、MongoDB、Redis、通知等配置。 |
| `dockerfile` | 以 `python:3.7-slim` 为基础镜像，安装运行时依赖，复制 `dist/ScopeSentry_linux_amd64_v1/ScopeSentry` 并设为其 ENTRYPOINT。 |
| `single-host-deployment.yml` | 单机 compose：`scopesentry-network` 桥接网络，含 `mongodb`（mongo:7.0.28，数据卷 `./data/mongodb`，带 healthcheck）、`redis`（redis:7.0.11）与服务本体。 |
| `single-host-deployment-fix.yml` | 同一部署拓扑的兼容变体（mongo 版本为 7.0.4）。 |
| `version.json` | `server` / `scan` 版本号与更新说明链接，供升级检查使用。 |
| `uploads/` | 运行期上传目录，通过 `/images` 静态路由对外暴露（路径由 `config.yaml` 的 `system.imgDir` 决定）。 |
| `interface/` | Swagger 接口文档包（`package apidocs`）：`docs.go` 为 swag 生成产物，`swagger.go` 为手写全局注解，`swagger.json` / `swagger.yaml` 为静态导出。由 `cmd/main` 导入并在 `/api/swagger/*any` 暴露。 |
| `docs/` | 项目文档与资源：架构文档 `__ARCHITECTURE.md`、扫描端关系 `__SCAN_RELATION.md`、MCP 指南 `SKILL.md`、流程图 `流程图.svg`；`images/` 为文档配图。 |

## 9. 阅读代码时的注意事项

1. **四个 “scheduler” 分属不同层次**：`api/routes/task`（路由）、`api/handlers/task`（处理器）、`internal/scheduler`（全局 gocron 调度器）、`internal/services/task/scheduler`（周期任务业务），切勿混淆。
2. **`internal/options` 是唯一的反向依赖**：它依赖 services/repositories 以便为插件构造依赖注入容器，新增插件能力通常需要在此扩展 `PluginOption`。
3. **插件可引用范围由 `internal/symbols` 决定**：新增内部包供插件使用时，需重新执行 `go generate` 生成符号表。
4. **`bootstrap .go` 文件名中间含空格**，为历史命名，检索时注意。
5. **前端产物已提交在 `cmd/main/static/`**：改动 `frontend` 后需重新构建并覆盖该目录，后端二进制才会带上最新界面。
