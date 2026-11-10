package main

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"os/signal"
	"path/filepath"
	"runtime"
	"strings"
	"syscall"
	"time"
)

func changeXrayVersion(reader *bufio.Reader, configPath string) error {
	if runtime.GOOS != "linux" || os.Geteuid() != 0 {
		return fmt.Errorf("切换内核需要 Linux root 权限")
	}
	cfg, err := loadMenuConfig(configPath)
	if err != nil {
		return err
	}
	current := "未知"
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	output, verErr := exec.CommandContext(ctx, cfg.XrayPath, "version").Output()
	cancel()
	if fields := strings.Fields(string(output)); verErr == nil && len(fields) > 1 {
		current = fields[1]
	}
	asset, err := xrayAssetName(runtime.GOARCH)
	if err != nil {
		return err
	}
	fmt.Println("正在获取官方 Xray 版本列表...")
	releases, err := fetchXrayReleases(context.Background(), xrayHTTPClient(), xrayReleaseAPI, asset)
	if err != nil {
		return err
	}
	selected, err := chooseXrayRelease(reader, os.Stdout, releases, current)
	if err != nil || selected == nil {
		return err
	}
	if strings.TrimPrefix(selected.Tag, "v") == current {
		fmt.Println("已是所选版本，无需切换。")
		return nil
	}
	fmt.Printf("将切换到 %s，服务会短暂重启。确认继续？[y/N]: ", selected.Tag)
	confirm, err := readMenuLine(reader)
	if err != nil {
		return err
	}
	if !strings.EqualFold(confirm, "y") {
		fmt.Println("已取消。")
		return nil
	}
	return switchXray(configPath, selected.Tag)
}

func atomicXrayCopy(source, destination string) error {
	in, err := os.Open(source)
	if err != nil {
		return err
	}
	defer in.Close()
	out, err := os.CreateTemp(filepath.Dir(destination), ".xray-replace-*")
	if err != nil {
		return err
	}
	defer os.Remove(out.Name())
	_, err = io.Copy(out, in)
	if err == nil {
		err = out.Chmod(0755)
	}
	if err == nil {
		err = out.Sync()
	}
	closeErr := out.Close()
	if err != nil {
		return err
	}
	if closeErr != nil {
		return closeErr
	}
	return os.Rename(out.Name(), destination)
}

type xraySwitchOps struct {
	active   func() (bool, error)
	stop     func() error
	start    func() error
	validate func(string) error
	healthy  func() error
}

// Only executable bytes are rolled back. Never restore state or traffic snapshots.
func replaceXray(candidate, destination string, ops xraySwitchOps) (backup string, err error) {
	active, err := ops.active()
	if err != nil {
		return "", fmt.Errorf("无法确认服务状态: %w", err)
	}
	info, err := os.Lstat(destination)
	if err != nil {
		return "", err
	}
	if !info.Mode().IsRegular() {
		return "", fmt.Errorf("Xray 路径必须是普通文件")
	}
	saved, err := os.CreateTemp(filepath.Dir(destination), ".xray-backup-*")
	if err != nil {
		return "", err
	}
	backup = saved.Name()
	saved.Close()
	if err = atomicXrayCopy(destination, backup); err != nil {
		os.Remove(backup)
		return "", err
	}
	stopped := false
	replaced := false
	defer func() {
		if err == nil {
			return
		}
		if replaced {
			stopErr := ops.stop()
			running, queryErr := ops.active()
			if queryErr != nil || running {
				err = errors.Join(err, fmt.Errorf("回滚中止：无法确认服务已停止（停止: %v，查询: %v）；备份: %s", stopErr, queryErr, backup))
				return
			}
			if restoreErr := atomicXrayCopy(backup, destination); restoreErr != nil {
				err = errors.Join(err, fmt.Errorf("恢复内核失败: %w；备份: %s", restoreErr, backup))
				return
			}
		}
		if active && stopped {
			if startErr := ops.start(); startErr != nil {
				err = errors.Join(err, fmt.Errorf("旧内核恢复启动失败: %w", startErr))
				return
			}
			if healthErr := ops.healthy(); healthErr != nil {
				err = errors.Join(err, fmt.Errorf("旧内核恢复健康检查失败: %w", healthErr))
				return
			}
		}
	}()
	if active {
		stopped = true
		if err = ops.stop(); err != nil {
			return backup, err
		}
	}
	running, queryErr := ops.active()
	if queryErr != nil {
		return backup, fmt.Errorf("无法确认服务已停止: %w", queryErr)
	}
	if running {
		return backup, fmt.Errorf("服务仍在运行，无法切换")
	}
	// Validate after stopping: low-memory nodes must not run two Xray processes.
	if err = ops.validate(candidate); err != nil {
		return backup, err
	}
	if err = atomicXrayCopy(candidate, destination); err != nil {
		return backup, err
	}
	replaced = true
	if active {
		if err = ops.start(); err != nil {
			return backup, err
		}
		if err = ops.healthy(); err != nil {
			return backup, err
		}
	}
	return backup, nil
}
func serviceCommand(args ...string) error {
	ctx, cancel := context.WithTimeout(context.Background(), 20*time.Second)
	defer cancel()
	return exec.CommandContext(ctx, args[0], args[1:]...).Run()
}
func switchXray(configPath, tag string) error {
	if runtime.GOOS != "linux" || os.Geteuid() != 0 || !supportedXrayTag(tag) {
		return fmt.Errorf("无效的版本或运行环境")
	}
	exe, err := os.Executable()
	if err != nil {
		return err
	}
	exe, err = filepath.EvalSymlinks(exe)
	if err != nil {
		return err
	}
	if err := standardXrayInstallation(exe, configPath); err != nil {
		return err
	}
	// Share the stable lock inode used by angelo-node-update.
	unlock, err := lockXrayUpdate(exe + ".update.lock")
	if err != nil {
		return err
	}
	defer unlock()
	cfg, err := loadMenuConfig(configPath)
	if err != nil {
		return err
	}
	if !filepath.IsAbs(cfg.XrayPath) || !filepath.IsAbs(cfg.StateDir) {
		return fmt.Errorf("内核和数据路径必须是绝对路径")
	}
	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer cancel()
	asset, err := xrayAssetName(runtime.GOARCH)
	if err != nil {
		return err
	}
	client := xrayHTTPClient()
	releases, err := fetchXrayReleases(ctx, client, xrayReleaseAPI, asset)
	if err != nil {
		return err
	}
	var selected *xrayRelease
	for i := range releases {
		if releases[i].Tag == tag {
			selected = &releases[i]
			break
		}
	}
	if selected == nil {
		return fmt.Errorf("所选版本已不在官方列表中，请刷新列表")
	}
	stage, err := os.MkdirTemp(filepath.Dir(cfg.XrayPath), ".xray-download-*")
	if err != nil {
		return err
	}
	defer os.RemoveAll(stage)
	fmt.Printf("正在下载并校验 %s...\n", tag)
	candidate, err := prepareXray(ctx, client, *selected, asset, stage)
	if err != nil {
		return err
	}
	if ctx.Err() != nil {
		return ctx.Err()
	}
	var state func() (bool, error)
	var stop, start []string
	if _, e := exec.LookPath("systemctl"); e == nil {
		state = func() (bool, error) {
			out, err := serviceOutput("systemctl", "show", "angelo-node.service", "--property=LoadState,ActiveState,ExecStart")
			if err != nil {
				return false, err
			}
			return parseSystemdXrayState(string(out))
		}
		stop = []string{"systemctl", "stop", "angelo-node.service"}
		start = []string{"systemctl", "start", "angelo-node.service"}
	} else if _, e = exec.LookPath("rc-service"); e == nil {
		state = func() (bool, error) {
			if err := serviceCommand("rc-service", "--exists", "angelo-node"); err != nil {
				return false, fmt.Errorf("OpenRC 服务不存在或不可查询: %w", err)
			}
			err := serviceCommand("rc-service", "angelo-node", "status")
			if err == nil {
				return true, nil
			}
			var exitErr *exec.ExitError
			if errors.As(err, &exitErr) && exitErr.ExitCode() == 3 {
				return false, nil
			}
			return false, fmt.Errorf("OpenRC 服务状态异常: %w", err)
		}
		stop = []string{"rc-service", "angelo-node", "stop"}
		start = []string{"rc-service", "angelo-node", "start"}
	} else {
		return fmt.Errorf("未找到 systemd 或 OpenRC")
	}
	ops := xraySwitchOps{active: state, stop: func() error { return serviceCommand(stop...) }, start: func() error { return serviceCommand(start...) }}
	ops.validate = func(path string) error {
		for _, args := range [][]string{{"version"}, {"run", "-test", "-config", filepath.Join(cfg.StateDir, "xray.json")}} {
			c, done := context.WithTimeout(context.Background(), 10*time.Second)
			cmd := exec.CommandContext(c, path, args...)
			limit := cfg.XrayMemoryLimit
			if limit == "" {
				limit = "24MiB"
			}
			cmd.Env = append(os.Environ(), "GOMEMLIMIT="+limit, "GOGC=50", "GOMAXPROCS=1", "XRAY_LOCATION_ASSET="+filepath.Dir(cfg.XrayPath))
			out, e := cmd.Output()
			done()
			if e != nil {
				return fmt.Errorf("所选 Xray 无法运行或不兼容当前配置: %w", e)
			}
			if args[0] == "version" {
				fields := strings.Fields(string(out))
				if len(fields) < 2 || fields[1] != strings.TrimPrefix(tag, "v") {
					return fmt.Errorf("下载内核版本与所选版本不一致")
				}
			}
		}
		return nil
	}
	ops.healthy = func() error {
		deadline := time.Now().Add(30 * time.Second)
		for time.Now().Before(deadline) {
			active, err := ops.active()
			if err != nil {
				return err
			}
			if active && serviceCommand(exe, "-config", configPath, "-health-check") == nil {
				return nil
			}
			time.Sleep(time.Second)
		}
		return fmt.Errorf("节点 API / Xray 健康检查超时")
	}
	// Finish the transaction or rollback even if Ctrl-C arrives after stopping.
	backup, err := replaceXray(candidate, cfg.XrayPath, ops)
	if err != nil {
		return fmt.Errorf("切换未完成: %w；旧内核备份: %s", err, backup)
	}
	fmt.Printf("Xray 已切换到 %s。旧内核备份: %s\n用户、流量、Token 和配置保持不变。\n", tag, backup)
	return nil
}
