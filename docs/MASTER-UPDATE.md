# 主面板独立升级与恢复

`scripts/update-master.sh` 用于已经部署的 `AngeloSakura/Angelo-xui-plugin-2` **主面板**。在主面板机器上运行；NAT 节点的升级由节点自己的升级器处理。两者不互相调用，不要求同时升级。

脚本只替换原安装目录里的面板可执行文件。SQLite 数据库、用户、入站、流量、API Token、节点密钥、证书、面板设置、systemd 服务配置、Xray 程序与 geodata 不由脚本覆盖。新版面板本身启动时可能执行数据库迁移，因此升级前有完整停机备份，失败时不盲目回灌旧数据库。

**面板停机和启动可能连带重启它管理的本机 Xray 进程，产生短暂中断。** “保留 Xray”指不替换其二进制、资源文件或主动运行 Xray 升级命令，不表示零中断。远程 NAT 节点不会被这个脚本升级。

## 支持范围

- Linux amd64/x86_64；现有 systemd 服务直接运行面板程序。
- Bash 4+、`curl`、Python 3.8+ 标准库（含 `sqlite3`）、常规 GNU 工具；root 执行。Python 只要求在主面板机器安装，NAT 节点不依赖 Python。
- 主面板必须已经运行，原页面健康检查必须通过；默认程序 `/usr/local/x-ui/x-ui`、服务 `x-ui.service`。
- 默认 SQLite 目录 `/etc/x-ui`；优先根据运行进程的 `XUI_DB_FOLDER` 找到实际目录。
- PostgreSQL、Docker、OpenRC、包装脚本作为 MainPID、systemd root 隔离、复杂/未落盘的环境继承及安装目录和数据库目录互相嵌套均拒绝自动升级，需单独制定备份与恢复方案。
- systemd 保存的数据库/密钥配置必须与当前运行进程一致。比如改了 `XUI_DB_FOLDER` 但没重启服务，脚本会拒绝，避免备份 A 数据库后启动到 B 数据库。
- systemd 已加载的 `WorkingDirectory` 必须与 `/proc/MainPID/cwd` 一致，`ExecStart` 必须直接启动同一个指定面板二进制且无附加参数。修改 unit 后只执行 `daemon-reload`、没有重启现有进程时，脚本拒绝路径漂移，防止新版启动到其他相对数据库目录或执行其他程序。
- 外部证书和 key 文件自动收集：面板/订阅证书、入站和 Xray 配置中的常见 `certificateFile`/`keyFile` 等字段、节点 Token keyring、systemd EnvironmentFile。特殊外部配置用 `--backup-path` 补充。
- 备份根目录建议放在本地持久化磁盘，不使用 `/tmp`、tmpfs 或网络挂载；预留下载包、完整安装目录、数据库目录及外部配置副本所需空间。自动升级期间不要编辑设置、环境文件或并行执行其他升级器。

## 执行

在主面板机器下载本项目发布的独立升级器，明确选择**主面板仓库**的稳定 release tag：

```bash
curl -fL --retry 3 https://github.com/AngeloSakura/angelo-nat-node/releases/download/v0.1.0/update-master.sh -o /tmp/angelo-master-update.sh
sudo bash /tmp/angelo-master-update.sh --version v1.0.0
```

若已下载完整源码，也可从仓库运行。不要用上游首次安装脚本代替此升级脚本：

```bash
sudo bash scripts/update-master.sh --version v1.0.0
```

自定义安装位置、备份目录或附加配置：

```bash
sudo bash scripts/update-master.sh \
  --version v1.0.0 \
  --service x-ui.service \
  --binary /usr/local/x-ui/x-ui \
  --backup-root /var/backups/angelo-master \
  --backup-path /etc/nginx/sites-enabled/x-ui
```

脚本从数据库读取端口、访问路径、监听地址、TLS 和 webDomain，检测本机面板页面。自定义反向代理/访问控制可指定明确的 loopback 地址：

```bash
sudo bash scripts/update-master.sh --version v1.0.0 \
  --health-url http://127.0.0.1:2053/your-panel-path/ \
  --startup-timeout 120
```

健康地址不能带账号、密码、query 或 fragment，不需要提交面板 API 密钥。健康检查仅向本机发送无凭据请求，不跟随重定向，要求 HTTP 200 和同一 MainPID 连续通过 10 次；本机 HTTPS 检查允许自签名证书。**下载 GitHub 资产仍严格校验 HTTPS 证书**。这不是所有业务功能已正常的证明，更新后仍应登录主面板核对用户、节点连接和流量。

`--version` 必填。不接受 `latest`、`dev-latest`、draft 或 prerelease。重复运行同一固定版本仍会先独立备份，再替换面板，不清空数据，也不碰 NAT 节点升级状态。

## 包验证与实际修改

脚本固定读取官方目标仓库的：

```text
https://api.github.com/repos/AngeloSakura/Angelo-xui-plugin-2/releases/tags/<指定版本>
```

1. 验证 tag、stable 状态、唯一的 `x-ui-linux-amd64.tar.gz` 资产及其准确 URL。
2. 使用 release asset 的 `digest: sha256:...`；缺失时只接受同一 release 发布的 `x-ui-linux-amd64.tar.gz.sha256`、`SHA256SUMS`、`SHA256SUMS.txt`、`sha256sums.txt` 或 `checksums.txt`。必须唯一匹配本资产名。
3. 摘要不可用、摘要不匹配、资产大小异常、非 amd64 ELF、多个/链接形式的面板成员均拒绝。失败发生在停服务之前。
4. 只读取归档内的普通文件 `x-ui/x-ui`；不解压整个包，不运行包内脚本，也不安装里面的 Xray。
5. 停止主面板并确认 MainPID 已消失，备份完整 SQLite 目录（包含 WAL/SHM/journal）、完整旧安装目录、systemd 配置和环境文件、已识别外部配置。
6. 校验备份 SQLite 完整性，记录逻辑内容/结构指纹；使用同目录临时文件和原子 rename 仅替换面板可执行文件，保留原文件所有者与普通权限。
7. 启动服务并检测稳定健康状态。

资产摘要是 GitHub/release 提供的完整性依据，不是额外的离线作者签名。本脚本没有“跳过校验”开关，也不会退回未校验的下载地址。GitHub API 限流或不可用时安全退出，原服务继续运行。

2026-11-07 实际核对的发布信息：

| 项目 | 内容 |
| --- | --- |
| 稳定 tag | `v1.0.0` |
| 发布时间 | `2026-08-28T12:19:41Z` |
| 资产 | `x-ui-linux-amd64.tar.gz` |
| 大小 | `80289955` 字节 |
| GitHub SHA256 | `96a6518eee572bc282ce5c56ece59b4b4f3332be9ee24ffd29e6993c3782f1a5` |

这些信息用于审计记录；脚本每次对指定版本重新获取摘要，不把该历史值用于其他版本。上游发布工作流确认面板成员路径为 `x-ui/x-ui`，并且归档包含 Xray，因此完整覆盖解压会改变 Xray，本脚本明确不做完整覆盖。

## 备份与失败恢复

默认目录形如：

```text
/var/backups/angelo-master/backup-20261107T120000Z-1234/
  sqlite/                    完整升级前数据库目录
  installation/              完整旧安装目录和旧面板程序
  service-config/            unit 内容及 systemd 属性
  external-config/           外部证书、私钥、环境文件等副本
  recovery.json              原路径映射、版本、SHA256、数据库指纹
  release.json               当次 release 元数据
  installed-version.txt      仅成功升级时写入
  sqlite-after-failed-start/  新版失败且能停机取证时生成
```

备份根目录权限为 0700；里面包含用户信息、流量和密钥。不要把备份、`recovery.json`、环境文件或数据库提交到 GitHub。脚本不打印这些内容，也不运行面板“显示密码/重置设置”命令。备份不自动删除，定期由管理员保留和清理。

失败分两种：

- **新程序未改变 SQLite 内容/结构**：停止失败的服务，恢复旧面板程序，再尝试启动并健康检查。升级命令仍返回非零，表示新版本安装失败。
- **SQLite 已改变或无法证明未改变**：停止服务，恢复旧面板程序，保留升级前和失败后的 SQLite；**服务保持停止**。不自动恢复旧 DB、不自动让旧程序运行新 schema，避免把迁移后的记录或新增流量覆盖掉。SQLite 的任何逻辑变化（不仅 schema）都会走这个保守分支。

恢复时先阅读 `recovery.json`，离线比较 `sqlite/` 与 `sqlite-after-failed-start/`，决定是修正新版本继续迁移还是恢复升级前状态。恢复旧数据库会丢掉备份之后的写入，不能在未比较时直接执行 `cp old.db live.db`。恢复必须在服务停止时进行，整个 SQLite 目录与 sidecar 文件作为一致集合处理，并检查所有权/权限；不要把新旧 WAL 混用。必要时先复制当前生产目录保留第三份取证副本，再由管理员执行明确的恢复方案。

若主面板无法停止、进程仍在运行或恢复旧二进制失败，脚本会明确报错，不宣称恢复完成。若更新过程被断电或 `kill -9` 中断，EXIT trap 不会运行；检查安装目录内 `.angelo-master-update.lock/pid` 对应的进程、完整备份、运行版本后再决定恢复。不要在更新仍运行时删除锁。锁跟随安装目录，即使两次指定不同备份目录也不能并行更新同一面板。

## PostgreSQL

脚本只要检测到 `XUI_DB_TYPE=postgres/postgresql/pg`、未知数据库类型或非空 `XUI_DB_DSN`，就在停服务前拒绝。不要通过伪装成 SQLite 绕过。

PostgreSQL 需要独立维护计划：确认实际数据库与 PostgreSQL 客户端版本、用安全凭据机制执行 `pg_dump`（推荐 custom format）、保留角色/权限与相关配置，在隔离数据库实测 `pg_restore`，协调写入停机窗口，并验证新旧面板 schema 兼容与回退路径。不能用旧 SQLite 副本恢复 PostgreSQL，也不能在未验证 schema 的情况下仅回退二进制。本脚本暂不提供 PostgreSQL 自动升级或“备份已完成”绕过参数。

## 本地回归验证与边界

```bash
bash -n scripts/update-master.sh
bash -n scripts/test-update-master.sh
bash scripts/test-update-master.sh
```

测试用真实临时 SQLite 数据、归档和文件操作；用 fixture ELF 和模拟 systemd/curl 替代真实服务及网络，不执行测试 ELF。14 例覆盖成功升级、重复升级、启动失败回滚、页面不健康回滚、迁移后失败保持停机、摘要错误/缺失、发布 checksum 回退、PostgreSQL 拒绝、恶意归档成员、非法 tag、保存环境与运行环境不一致、已加载工作目录漂移、已加载启动程序漂移。每例检查用户/入站/流量/API Token/key/config/Xray 的保留以及输出中无测试秘密。

测试可以在 Linux 或 Git Bash + Python 运行。它证明脚本控制流及文件保留，不替代真实 Linux systemd、真实发布二进制、生产规模数据库迁移和业务流量的验收；发布前需由独立审查和集成环境完成这些检查。

本项目另已通过真实Linux systemd + 固定SHA v1.0.0发布二进制的同版本升级演练，验证登录、API Token、用户/入站、非零流量、倍率和Xray文件保留。见 [完整记录](VALIDATION.md)。跨版本数据库迁移、加密Token模式及用户生产数据库不在该演练覆盖范围内。
