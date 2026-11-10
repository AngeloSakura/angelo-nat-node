# Alpine OpenRC 安装兼容

## 功能目的

让 Alpine Linux（默认 OpenRC）可以使用节点发布包完成安装、开机启动、健康检查和后续节点程序更新；systemd Linux 的原有安装路径继续保留。

## 适用角色与入口

- 适用角色：拥有 Alpine NAT VPS root 权限的运维人员。
- 入口：发布页 `install.sh`，安装后使用 `/etc/init.d/angelo-node` 和 `rc-service` 管理。

## 操作步骤

1. 安装 Alpine 依赖 `curl`、`tar`、`sha256sum`、`install`、`flock`、`unzip`、`rc-service`、`rc-update`。
2. 下载并执行对应版本的 `install.sh`；安装器自动检测 OpenRC，写入 `/etc/init.d/angelo-node`，加入 `default` 运行级别并启动服务。
3. 使用 `rc-service angelo-node status` 和 `/usr/local/bin/x-ui -health-check` 验证结果；升级时运行 `/usr/local/bin/angelo-node-update <固定版本>`。

## 关键业务规则

- 只有检测到 `systemctl` 或同时检测到 `rc-service`、`rc-update` 时才允许安装。
- systemd 使用 `angelo-node.service`；OpenRC 使用 `angelo-node`，两个服务文件都随发布包提供，安装器只部署当前后端需要的文件。
- 安装仍拒绝已有配置、状态、可执行文件或服务文件，避免覆盖节点身份、Token、证书和累计计数。
- OpenRC 启动失败时停止服务并移除 `default` 自启项，保留已经生成的配置和状态供恢复。
- 节点更新只替换 `x-ui`，服务启停通过当前检测到的服务后端完成，状态目录和 Xray 不由更新器覆盖。

## 涉及文件

- `scripts/install.sh`
- `scripts/update-node.sh`
- `scripts/angelo-node.openrc`
- `scripts/angelo-node.service`
- `scripts/package.sh`
- `README.md`

## 验证记录

- 已完成：Windows 工作区文本审查、安装器/更新器分支与归档成员静态核对；新发布版本为 v0.1.2，管理进程名沿用原版 3x-ui 的 x-ui，Xray 进程名为 xray。
- v0.1.3 已实现：安装器自动补齐 unzip 等系统依赖，安装时询问端口和访问路径；x-ui 无参数进入管理菜单，账号密码不提供，认证仅保留 Bearer Token。
- v0.1.4 已实现：安装完成后在交互终端直接进入 x-ui；菜单提供 latest 安全更新和卸载，卸载只需输入 y 确认；非交互安装自动使用默认端口和路径。
- v0.1.5 已实现：Release 同时包含独立节点升级器 update-node.sh。
- v0.1.7 已实现：Go 初始化再次规范化 API 路径，安装回归测试检查自定义路径最终正确写入配置为标准路径。安装端口和路径输入错误时继续提示，路径自动补齐前导斜杠；Xray ZIP 检查兼容 BusyBox。`r`n- v0.1.8 计划：路径提示改用中性示例 node-path，明确无需输入 /。
- 待 CI 验证：Linux shell 语法、既有 systemd 安装保护测试、跨架构打包与发布包校验。
- 待 Alpine 实机验证：OpenRC 服务启动、停止、重启、开机自启和更新失败回滚；当前工作区没有 Alpine/OpenRC 运行环境。
