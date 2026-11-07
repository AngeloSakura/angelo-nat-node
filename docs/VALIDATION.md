# 发布验证记录

本文件记录实际验证范围。尚未写明 PASS 的项目不得视为已通过；CI 原始记录和发布资产 SHA256 是交付依据。

## 测试对象

- 主面板源码基线：AngeloSakura/Angelo-xui-plugin-2 `bb0bf320301fb03d1975ff1489e36f13324f15d7`。
- 原版 Xray：v26.10.31，安装包由上游 SHA256 验证；未修改源码、未重编译 Xray。
- Go 应用包含协议模拟/持久化回归、真实 Xray 代理请求、额度停用恢复、重启计数；Windows 开发环境与 Linux CI 分开记录。
- API 并发限制作用于管理面，不是代理连接数/带宽限速。

## 审查发现与处理

独立 Standards 和 Spec 两条审查已执行，发现后均先复现再修复：

| 范围 | 修复 |
| --- | --- |
| GET 被配置重启阻塞 | 提供已提交不可变快照，更新期间读取继续响应 |
| 失败启动/回退漏计 | 任何运行实例替换后失效统计基线 |
| 后台启动无截止 | 有界启动与回退超时 |
| 解绑后丢共享用户用量 | 保留 detached 记录，明确删除才清理 |
| 分批全局流量覆盖遗漏用户 | 按主面板和 email upsert，空/部分推送不清旧行 |
| 延迟到期/额度停用不持久 | 首次使用确定统一到期时间，停用持久化 |
| 共享用户改名和多入站调用 | 计数/overlay 一次迁移，保留未选入站属性，后续调用可继续 |
| disableFlow 无效 | 渲染时移除对应 flow |
| 容量超限后无法重启 | 补齐用户记录后校验保存总量 |
| 大用量整数溢出绕过额度 | 饱和累加和不溢出的比较 |
| 错误 clients 形状清空用户 | 拒绝非数组 clients |
| 更新检查新建空状态 | -check 严格只读，缺失状态失败 |
| 健康检查缓存掩盖 Xray 退出 | 使用独立实时健康 API，检查实际 stats 通信 |
| 主面板运行/已加载服务目录不一致 | 更新前拒绝 WorkingDirectory、ExecStart、环境配置漂移 |
| CI 管道掩盖测试失败 | 所有 run 显式 Bash pipefail |

## 本机验证

2026-11-07，Windows amd64，Go 1.26.10：`XRAY_BINARY=<官方xray.exe> go test ./... -count=1` 与 `go vet ./...` PASS。真实请求实际经过原版 VLESS 服务，再检查额度停用、重置和重启后的累计流量。最初 AdGuard 影响 stats 通信；关闭后发现新版核心默认屏蔽回环目标，测试 fixture 为自身本地 HTTP 服务增加精确目的地址/端口 allow 规则，默认安装未改变这项行为。

## Linux 发布门槛

最终 Linux CI 结果、内存数据和构建资产将在发布前填入本节。更新脚本的 mock 测试验证真实文件/SQLite/归档保留与错误路径，模拟 systemd/网络；不等同于对用户生产数据库执行升级。

2026-11-07 的中间验证记录：

- `2f7fa0d`：Go vet、race 与官方 Xray 联调、主面板 14 场景/节点升级 10 场景均通过；未限制 TCP socket 时，64 MiB 突发测试触发 OOM。此提交未发布。
- `ce2630c`：[CI 42380048478](https://github.com/AngeloSakura/angelo-nat-node/actions/runs/42380048478) 全通过，包括安装保护和 8/32 路各传 8 MiB 的突发；已加入 socket 上限。早期 cgroup 峰值可能未包含此前测试加载并由其他组记账的共享可执行页，故该轮的 12.87/12.66 MiB **不用于最终内存承诺**。
- 后续测量为每次运行复制独立可执行文件 inode，fsync 后执行 POSIX_FADV_DONTNEED，再在 cgroup 内冷启动，额外报告所有组内进程 RSS/PSS、匿名页及 socket 缓冲峰值。RSS 求和会重复统计共享页，PSS 按比例计算，两者均是采样值；cgroup memory.peak 为内核记录。
- 本地 `govulncheck`（v1.9.0）扫描当前依赖与可达代码：No vulnerabilities found；这不是对未来漏洞或全部逻辑正确性的保证。

真实 master smoke 使用固定 SHA 的上游 v1.0.0 二进制及其原版 Xray、临时 SQLite 和真实 systemd。同版本更新测试不代表跨版本数据库迁移或生产数据全覆盖。互操作测试由主控实际创建节点和客户端、计算 2.5 倍、下发全局流量并停用节点；不使用伪造全局推送代替主控。
