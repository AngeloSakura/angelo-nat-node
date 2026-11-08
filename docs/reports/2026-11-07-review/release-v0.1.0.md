# v0.1.0 历史发布说明

> 历史记录（2026-11-07），本次仅归档，未重新执行审查或测试。初始失败、后续修复和当时未验证的边界按原记录保留；发布时结果见[发布验证](../../VALIDATION.md)，实机结论见[全部报告](../README.md)。文中 work/ 路径为原本地工作目录，不是公开可用的部署路径。

> 此页为 v0.1.0 历史发布说明，包含旧进程名和旧安装命令。当前部署请查看[仓库首页](../../../README.md)。

适用于小内存 NAT VPS 的无界面节点。保留官方原版 Xray，通过已有的 [Angelo-xui-plugin-2](https://github.com/AngeloSakura/Angelo-xui-plugin-2) 主面板 API Token 管理入站和用户，兼容主面板流量倍率。

- 不运行本地网页面板、SQLite、订阅服务或 Telegram；倍率只由主面板计算。
- 保留用户、Token、GUID、配置和累计流量。节点升级与主面板升级相互独立，提供备份和失败处理，不用旧计数覆盖新计数。
- Linux TCP 默认限制每连接发送/接收缓冲，减少突发并发带来的内存压力。Xray 二进制和源码未修改。
- 提供 Linux amd64、arm64、386、armv7 预编译包；运行验证为 amd64，其他架构完成交叉编译。

安装到新的 systemd Linux 节点：

```bash
curl -fL --retry 3 https://github.com/AngeloSakura/angelo-nat-node/releases/download/v0.1.0/install.sh -o /tmp/angelo-node-install.sh
sudo sh /tmp/angelo-node-install.sh v0.1.0
sudo angelo-node -show
```

在主面板添加节点，填写 NAT 公网地址、API 外部映射端口、HTTPS、Token，使用 pin 模式绑定输出的 TLS SHA256 指纹。代理入站端口需要另行映射。

安装器需要 root、curl、tar、sha256sum、systemctl、install、flock；下载原版 Xray 时还需要 unzip。安装器不迁移旧 x-ui 数据，也不停止旧面板；旧服务占用的端口需要先规划切换。重复安装拒绝覆盖，后续使用 `sudo angelo-node-update <固定版本>`。

主面板机器使用独立的 `update-master.sh`，目标版本来自主面板仓库。用法与备份、恢复边界见 [主面板升级说明](https://github.com/AngeloSakura/angelo-nat-node/blob/v0.1.0/docs/MASTER-UPDATE.md)。日常密钥连接和倍率控制无需先升级主面板。

验证：最终提交 `3b53bbe4106828f86919449a31348ca4b20c67e3` 的 [完整 Linux CI](https://github.com/AngeloSakura/angelo-nat-node/actions/runs/42381807763) 三组全部通过：Go vet/race/原版 Xray 真实流量、安装及更新保留、真实主面板升级、真实主面板 2.5 倍计费与节点额度停用/恢复。独立 Spec/Standards 代码审查发现的问题已经修复并通过回归。

最终冷启动内存测试将管理进程和 Xray 一起置于无 swap 的 cgroup，32 路各传 8 MiB：64 MiB 限额组峰值 49.21 MiB；128 MiB 限额组峰值 49.34 MiB，两组均无 OOM。原始结果附于 `memory-results.json`，Go 测试输出附于 `go-tests.txt`。这是 VLESS TCP 测试，**不包含操作系统，不能保证整台 64 MiB VPS 足够**；实际优先推荐 128 MiB。TLS/REALITY、UDP、大量用户和长时慢连接未完成同等压力验证。缩小 TCP 缓冲会影响高时延单连接吞吐。

更新配置会顺序重启 Xray，现有连接中断；强杀或断电可能损失最后采样间隔内的流量。主面板断联时无法即时执行新的全局倍率用量。其他兼容边界、支持协议及部署步骤见 [README](https://github.com/AngeloSakura/angelo-nat-node/blob/v0.1.0/README.md) 和 [验证记录](https://github.com/AngeloSakura/angelo-nat-node/blob/v0.1.0/docs/VALIDATION.md)。

发布安装包及两个脚本由最终成功 CI 生成，`SHA256SUMS` 用于校验；Xray 不包含在节点压缩包内，安装器复用已有文件或下载并校验固定官方版本。
