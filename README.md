# Angelo NAT Node

面向小内存 NAT VPS 的无界面节点：保留原版 Xray 二进制，用轻量 Go API 进程替代整套 3x-ui。已有的 [Angelo-xui-plugin-2 主面板](https://github.com/AngeloSakura/Angelo-xui-plugin-2) 通过 API Token 管理入站、用户和流量；倍率只由主面板计算。

这是独立节点程序，不是完整 3x-ui。节点没有网页、SQLite、订阅服务、Telegram、自动更新线程，也不把 Xray 核心链接进自己的进程。NAT VPS 上直接运行预编译包，无需 Go、Node.js、Python 或 Docker。

## 内存与适用范围

- 默认管理进程 `GOMEMLIMIT=12MiB`，Xray `24MiB`，两者 `GOGC=50`、`GOMAXPROCS=1`。这是 Go 堆软目标，**不是总 RSS 硬上限**。
- Xray 每连接缓冲配置为 4 KiB；关闭逐连接 access 日志。API 限制 8 个连接、4 个并发请求、每请求 1 MiB；默认最多 16 入站、64 个已保存用户（含暂时解绑用户）。
- 突发高带宽不等于必然按传输字节数累积内存，但更多并发连接、TLS/REALITY 握手、UDP、内核 socket 缓冲都会增加占用。无法在不限制实际业务的情况下保证任意流量都适合 64 MiB。
- 发布验证在 Linux 将**管理进程和原版 Xray 一起**放入 64/128 MiB、无 swap cgroup，实际传输并记录峰值。测试包含 8/32 路同时传输；原始数据和范围见 [验证记录](docs/VALIDATION.md)。
- 该 cgroup 不包含 VPS 操作系统和其他服务，不能等同于完整 64 MiB VPS 保证。优先选择 128 MiB；64 MiB 只建议少量连接、简单配置并观察系统剩余内存。

## 安装

支持 systemd Linux：amd64、arm64、386、armv7；运行验证以 Linux amd64 为准，其他架构仅交叉编译。需要 root、`curl`、`tar`、`sha256sum`、`systemctl`、`install`、`flock`；下载官方 Xray 时还需要 `unzip`。

```bash
curl -fL --retry 3 https://github.com/AngeloSakura/angelo-nat-node/releases/download/v0.1.0/install.sh -o /tmp/angelo-node-install.sh
sudo sh /tmp/angelo-node-install.sh v0.1.0
sudo angelo-node -show
```

安装器校验版本包 SHA256。默认复用已安装的 Xray（复制字节，不改旧文件），找不到时下载固定官方 `v26.10.31` 并校验预设 SHA256。也可显式指定：

```bash
sudo env XRAY_BINARY=/usr/local/x-ui/bin/xray-linux-amd64 \
  ANGELO_LISTEN=:2053 sh /tmp/angelo-node-install.sh v0.1.0
```

已有配置时安装器直接退出；**重复安装不是升级方法**。它不导入、不删除旧 x-ui 数据库，不停止旧 x-ui。旧面板和新节点不能同时占用相同 API/代理端口，请先保留旧配置、计划切换，并在新节点验证成功后手动停用旧节点面板。

## 主面板连接 NAT 节点

1. 在 NAT 提供商控制台配置 TCP 映射：一个用于管理 API，另一个或多个用于实际代理入站。入站监听的是 VPS 内部端口，客户端使用映射后的外部端口；需要 UDP 的协议另配 UDP 映射。
2. 节点运行 `sudo angelo-node -show`，读取 API Token 和 TLS SHA256 指纹。Token 是完整管理权限密钥，不要公开。
3. 已有 Angelo 主面板的节点管理中添加节点：协议 `https`，地址填 NAT 公网 IP/域名，端口填 API **外部映射端口**，basePath `/`，填节点 Token。
4. TLS 验证选 `pin`，`pinnedCertSha256` 填本机输出的指纹。自签名证书默认不匹配公网域名，使用明确指纹绑定；不要长期选择跳过验证。确实通过可信内网连接时，按主面板要求开启私网地址许可。
5. 先测试连接，再在主面板创建/同步入站和客户端。节点 `GUID` 首次创建后持久保存；升级时不变化。
6. `trafficMultiplier` 在主面板设置，例如 3。节点向主面板始终返回原始累计字节，主面板计算倍率和全局用量，再下发已计费额度供节点停用判断。不要在节点重复乘倍率。

主面板必须能主动访问节点 API。本项目不创建反向隧道，也不能绕过供应商未提供的端口映射。生产上建议把 API 端口的防火墙来源限制到主面板地址。

## 独立升级，不重置数据

节点升级只替换管理程序，备份原程序、指定的 config.json 和整个状态目录，保留 Token、证书、GUID、用户、计数以及原版 Xray。证书文件及其他外部配置需另行备份：

```bash
sudo angelo-node-update v0.1.0
sudo angelo-node -health-check
```

必须填写固定版本；不会自动追踪 latest。新版本启动失败会尝试恢复旧可执行文件，**不回灌旧计数覆盖新计数**。旧程序无法读取新 schema 时保留备份并停机等待恢复，不宣称成功。自定义路径参数见 `angelo-node-update --help`。

主面板在主面板机器使用单独的 [主面板升级脚本和恢复说明](docs/MASTER-UPDATE.md)。它只替换原主面板可执行文件，不覆盖 SQLite、用户、密钥、设置或 Xray，不调用节点升级。主面板新二进制可能自行迁移数据库，因此必须保留升级前备份；迁移后失败不盲目回滚数据库。

## 配置、状态与维护

| 项目 | 默认位置 |
| --- | --- |
| 管理程序 | `/usr/local/bin/angelo-node` |
| 配置、Token、TLS | `/etc/angelo-node/` |
| 用户和累计计数 | `/var/lib/angelo-node/state.json` |
| 生成的 Xray 配置 | `/var/lib/angelo-node/xray.json` |
| 原版 Xray 副本 | `/usr/local/lib/angelo-node/xray` |
| 更新备份 | `/var/backups/angelo-node/` |

```bash
sudo systemctl status angelo-node
sudo journalctl -u angelo-node -n 50 --no-pager
sudo angelo-node -check         # 严格只读，缺失状态会报错，不新建用户库
sudo angelo-node -health-check  # 验证当前 Xray stats 响应和节点 API
```

修改配置需重启服务。修改 `stateDir` 时还需同步 systemd 的 `ReadWritePaths` 并迁移完整状态目录，不能把空目录当成更新。不要删除 state.json 来修复启动错误，否则会失去节点身份和累计计数。

`directOutboundSettings` 是可选的原版 Xray freedom 出站设置，默认不覆盖原版行为。测试仅使用精确回环地址/端口 allow 规则连接本机测试服务；默认安装不开放私网目的地址。其他路由、geodata、DNS、多出站自定义暂不提供面板同步。

## 支持边界

- 已审计主面板基线：`bb0bf320301fb03d1975ff1489e36f13324f15d7`（v3 客户端 API）。支持 VLESS、VMess、Trojan、Shadowsocks；传输参数交给原版 Xray 校验。真实流量测试覆盖 VLESS TCP；其他协议没有相同规模的实测，不应将兼容判断当成全协议保证。
- 支持启停、增删改入站/用户、原始流量、有效期、额度限制、共享用户、客户端重置。客户端重置清本用户计数；入站重置不清用户累计流量。
- 拒绝 IP 数量限制、自动续期/周期重置、非上述协议；没有 AmneziaWG、Hysteria 等 sidecar。在线列表基于近期流量，不能提供客户端 IP/准确入站归属。CPU/网卡监控不实现，面板显示 0 并在 API 声明不可用。订阅由主面板负责。
- 配置改变时顺序停止、校验、启动原版 Xray，避免两份 Xray 同时占内存；现有连接会中断。没有承诺无损热更新。校验失败恢复旧运行配置。
- 默认每 10 秒采集并落盘。正常停机先采集；强杀、断电、采样到停核间的尾部字节可能丢失，本实现不承诺逐字节结算级审计。
- 倍率只由主面板算；断联期间节点无法预知最新全局倍率用量，可能超用。最近 24 小时内任一主面板下发用量达限或本地原始用量达限均停用，停用后不会因数据过期自动恢复。需要主面板明确启用/重置。
- 已发现所审计主面板远端入站流量重置的 ID 映射问题，见 [最小可选修补](docs/patches/README.md)。普通同步和倍率功能不要求打该补丁；补丁不涉及数据库重置。

## 开发与审查

```bash
go test ./...
go vet ./...
XRAY_BINARY=/path/to/original/xray go test -race -count=1 ./...
bash scripts/test-update-master.sh
sudo bash scripts/test-update-node.sh
bash scripts/package.sh
sudo python3 scripts/memory-test.py dist/angelo-node-linux-amd64 /path/to/original/xray
```

编译在有足够内存的开发机/CI 上完成。GitHub Actions 同时校验协议、原版 Xray、更新保留、跨架构打包与内存约束；测试管线启用 pipefail，失败不能被 tee 掩盖。详见 [协议说明](docs/PROTOCOL.md)、[需求](SPEC.md)、[验证记录](docs/VALIDATION.md)。

GPL-3.0。Xray 不随节点包打入，安装时的原版 Xray 保持其上游许可；本项目与上游 3x-ui/Xray 独立。
