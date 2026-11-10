package main

import (
	"context"
	"fmt"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// Switching controls the installer-managed service, never a custom instance.
func standardXrayInstallation(exe, configPath string) error {
	if filepath.ToSlash(exe) != "/usr/local/bin/x-ui" || filepath.ToSlash(configPath) != "/etc/angelo-node/config.json" {
		return fmt.Errorf("自动切换仅支持标准安装 /usr/local/bin/x-ui 和 /etc/angelo-node/config.json")
	}
	return nil
}

func serviceOutput(args ...string) ([]byte, error) {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, args[0], args[1:]...).Output()
	if err != nil {
		return nil, fmt.Errorf("查询服务失败: %w", err)
	}
	return out, nil
}

func parseSystemdXrayState(output string) (bool, error) {
	properties := make(map[string]string)
	for _, line := range strings.Split(output, "\n") {
		key, value, ok := strings.Cut(line, "=")
		if ok {
			properties[key] = value
		}
	}
	if properties["LoadState"] != "loaded" {
		return false, fmt.Errorf("angelo-node.service 未正常加载: %s", properties["LoadState"])
	}
	if !strings.Contains(properties["ExecStart"], "argv[]=/usr/local/bin/x-ui -config /etc/angelo-node/config.json ;") {
		return false, fmt.Errorf("angelo-node.service 启动命令与标准安装不匹配")
	}
	switch properties["ActiveState"] {
	case "active":
		return true, nil
	case "inactive":
		return false, nil
	default:
		return false, fmt.Errorf("angelo-node.service 状态异常或正在变化: %s", properties["ActiveState"])
	}
}
