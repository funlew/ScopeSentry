# 服务端本地开发（Docker Compose）

一套编排跑起 MongoDB + Redis + 服务端，改 Go 代码自动重新编译重启，可挂调试器。
扫描端（`../ScopeSentry-Scan`）接入同一个网络，见文末。

```bash
docker compose -f docker-compose.dev.yml up -d --build
```

首次启动会拉镜像、下载全部 Go 依赖并编译，通常 5～15 分钟；`docker compose -f docker-compose.dev.yml logs -f scope-sentry` 可看进度。

---

## 1. 组成

| 服务 | 镜像 / 构建 | 端口 | 说明 |
|---|---|---|---|
| `mongodb` | `mongo:7.0.4` | 27017 | 结果与配置真相源，卷 `mongo-data` |
| `redis` | `redis:7.0.11` | 6379 | 控制面消息总线，卷 `redis-data` |
| `scope-sentry` | 本仓库 `Dockerfile.dev` | 8082 / 2345 | 服务端，源码挂载 + air 热重载 |

固定网络 `scopesentry-dev`（`name:` 显式指定），扫描端 compose 以 external 方式接入，服务名 `mongodb` / `redis` 在两栈之间都有效。

默认凭据来自仓库根目录 `.env`：`admin` / `mongodb_password`、Redis `redis_password`。

---

## 2. 首次启动会得到什么

服务端把「可执行文件所在目录」当作运行根（`internal/config/config.go:88`），开发镜像里该目录是 `/data`，通过 `./.dev-data` 挂到宿主：

```
.dev-data/
├── ScopeSentry           air 的编译产物
├── config.yaml           由默认值 + 环境变量生成
├── PASSWORD              首次初始化生成的管理员密码
├── PLUGINKEY             插件二次校验密钥
├── files/export/         导出文件
├── images/{icon,screenshots}/
└── uploads/
```

登录：`http://127.0.0.1:8082`，用户名固定 `ScopeSentry`，密码：

```bash
cat .dev-data/PASSWORD
```

数据库为空时 `CreateDatabase()` 会自动写入管理员、系统配置（含 `ModulesConfig`、时区、指纹、字典等），**不需要手工初始化**。扫描端依赖的 `modules.yaml` 就是从这里下发的。

> `.dev-data/` 已在 `.gitignore` 中。想彻底重来：`docker compose -f docker-compose.dev.yml down -v && rm -rf .dev-data`。

---

## 3. 配置优先级

服务端与扫描端不同：**环境变量始终覆盖 `config.yaml`**（`loadFromEnv()` 在 `viper.ReadInConfig()` 之后执行），所以改 compose 里的连接信息后重启即可生效，不必删文件。

`config.yaml` 每次启动都会被重新写回，手工改它会被覆盖；要改默认值请改 compose 的 `environment`。

---

## 4. 热重载

`.air.toml`：源码变更 → `go -C /src build -o /data/ScopeSentry ./cmd/main/main.go` → 由 `dev/run-server.sh` 在 `/data` 下启动。

- 监控：`cmd/`、`internal/`、`pkg/` 下的 `.go`、`.yaml`、`.yml`、`.json`
- 排除：`frontend/`、`cmd/main/static/`、`docs/`、`uploads/` 等
- 构建必须指定单文件 `./cmd/main/main.go`，因为 `cmd/main/basic_usage.go` 也有 `func main()`

注意 air 开启了 `exclude_unchanged`，`touch` 不会触发重建，必须改内容。

---

## 5. 调试

### 5.1 日志

标准输出 + `logs.level` 控制级别；`docker compose -f docker-compose.dev.yml logs -f scope-sentry`。

### 5.2 Delve 远程断点

air 占用 8082，先停掉它，再用同一个镜像起一个调试容器：

```bash
docker compose -f docker-compose.dev.yml stop scope-sentry

docker compose -f docker-compose.dev.yml run --rm --service-ports scope-sentry \
  sh -c 'go -C /src build -gcflags="-N -l" -o /data/ScopeSentry.dbg ./cmd/main/main.go \
         && cd /data && exec dlv --headless --listen=:2345 --api-version=2 --accept-multiclient exec /data/ScopeSentry.dbg'
```

`-gcflags="-N -l"` 只影响本项目包（约 10 秒，依赖复用缓存）；要单步进依赖代码换成
`-gcflags="all=-N -l"`，首次会重编全部依赖。

调试结束后 `docker compose -f docker-compose.dev.yml start scope-sentry` 恢复热重载。

VS Code `.vscode/launch.json`：

```json
{
  "version": "0.2.0",
  "configurations": [
    {
      "name": "Attach to ScopeSentry (docker)",
      "type": "go",
      "request": "attach",
      "mode": "remote",
      "remotePath": "/src",
      "port": 2345,
      "host": "127.0.0.1",
      "substitutePath": [{ "from": "${workspaceFolder}", "to": "/src" }]
    }
  ]
}
```

要点：二进制必须放在 `/data`，且工作目录是 `/data` —— `PLUGINKEY` 是相对路径写入的，配置与数据目录也都由可执行文件位置推导。

---

## 6. 前端开发

界面产物已提交在 `cmd/main/static/` 并在编译期 `go:embed`，所以**只改后端不需要动前端**。

需要调 UI 时在宿主跑 vite（`frontend/vite.config.ts` 的代理固定指向 `127.0.0.1:8082`，正好命中已发布的服务端端口）：

```bash
cd frontend
pnpm install
pnpm dev          # http://127.0.0.1:4000
```

改完前端后要回灌到后端：

```bash
pnpm build:pro
rm -rf ../cmd/main/static && cp -r dist-pro ../cmd/main/static
docker compose -f docker-compose.dev.yml restart scope-sentry   # 触发 air 重新编译
```

`.air.toml` 不监控 `cmd/main/static/`，所以这一步必须重启，否则新界面不会被 embed 进二进制。

---

## 7. 与扫描端联动

扫描端工程与本节在同一父目录时：

```bash
# 1) 服务端 + 中间件（会创建网络 scopesentry-dev）
cd ScopeSentry && docker compose -f docker-compose.dev.yml up -d --build

# 2) 扫描端
cd ../ScopeSentry-Scan && docker compose -f docker-compose.dev.yml up -d --build
```

扫描端 compose 用 `mongodb` / `redis` 服务名连接中间件。若网络尚未创建，扫描端会报 `network scopesentry-dev declared as external, but could not be found` —— 先起服务端即可。

---

## 8. 常见问题

| 现象 | 处理 |
|---|---|
| `bind: address already in use`（27017/6379/8082） | 本机已有同名容器或本地 mongod/redis，先停掉 |
| `main redeclared in this block` | 构建未指定单文件，检查 `.air.toml` 的 `cmd` |
| 首次构建卡在 `go: downloading` | 换代理重建：`GOPROXY=https://proxy.golang.org,direct docker compose -f docker-compose.dev.yml build --no-cache scope-sentry` |
| 服务端起来但扫描端一直没任务 | 检查 8082 能否打开、扫描端日志里是否 `Register Success` |
| 数据库连不上且日志只有 `failed to ping MongoDB` | 确认 `MONGODB_IP=mongodb` 且两栈都在 `scopesentry-dev` 网络上：`docker network inspect scopesentry-dev` |
| 想换 air/dlv 版本 | 构建参数 `--build-arg AIR_VERSION=vX.Y.Z`，需其 `go.mod` 的 go 指令 ≤ 1.24 |
| 前端改了没生效 | 见第 6 节，需要覆盖 `cmd/main/static` 并重启容器 |

---

## 9. 发布前验证

开发镜像编译的是宿主架构产物，与线上 linux/amd64 不同。上线前用线上 `dockerfile`：

```bash
GOTOOLCHAIN=go1.24.6 CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
  go build -o dist/ScopeSentry_linux_amd64_v1/ScopeSentry ./cmd/main/main.go

docker build --platform linux/amd64 -t scopesentry:dev .
```

`dockerfile:16` 依赖 goreleaser 产物路径 `dist/ScopeSentry_linux_amd64_v1/`，也可直接 `goreleaser build --snapshot --clean`。
