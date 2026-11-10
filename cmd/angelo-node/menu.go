package main

import (
	"bufio"
	"crypto/rand"
	"encoding/hex"
	"encoding/json"
	"fmt"
	"net"
	pathpkg "path"
	"os"
	"os/exec"
	"strconv"
	"strings"

	"github.com/AngeloSakura/angelo-nat-node/internal/node"
)

func runInteractiveMenu(configPath string) error {
	reader := bufio.NewReader(os.Stdin)
	for {
		fmt.Println()
		fmt.Println("Angelo NAT Node")
		fmt.Println("1. 查看连接信息")
		fmt.Println("2. 修改 API 端口")
		fmt.Println("3. 修改访问路径")
		fmt.Println("4. 重置 API Token")
		fmt.Println("5. 重启服务")
		fmt.Println("6. 健康检查")
		fmt.Println("0. 退出")
		fmt.Print("请输入选项: ")

		choice, err := readMenuLine(reader)
		if err != nil {
			return err
		}
		switch choice {
		case "1":
			if err = showMenuConfig(configPath); err != nil {
				fmt.Printf("操作失败: %v\n", err)
			}
		case "2":
			if err = changeMenuPort(reader, configPath); err != nil {
				fmt.Printf("操作失败: %v\n", err)
			}
		case "3":
			if err = changeMenuBasePath(reader, configPath); err != nil {
				fmt.Printf("操作失败: %v\n", err)
			}
		case "4":
			if err = resetMenuToken(configPath); err != nil {
				fmt.Printf("操作失败: %v\n", err)
			}
		case "5":
			if err = restartNodeService(); err != nil {
				fmt.Printf("操作失败: %v\n", err)
			} else {
				fmt.Println("服务已重启。")
			}
		case "6":
			cfg, loadErr := loadMenuConfig(configPath)
			if loadErr != nil {
				fmt.Printf("操作失败: %v\n", loadErr)
				continue
			}
			if err = healthCheck(cfg); err != nil {
				fmt.Printf("健康检查失败: %v\n", err)
			}
		case "0":
			return nil
		default:
			fmt.Println("无效选项，请重新输入。")
		}
	}
}

func readMenuLine(reader *bufio.Reader) (string, error) {
	line, err := reader.ReadString('\n')
	if err != nil {
		return "", err
	}
	return strings.TrimSpace(line), nil
}

func loadMenuConfig(path string) (node.Config, error) {
	b, err := os.ReadFile(path)
	if err != nil {
		return node.Config{}, err
	}
	var cfg node.Config
	if err = json.Unmarshal(b, &cfg); err != nil {
		return node.Config{}, err
	}
	return cfg, nil
}

func showMenuConfig(path string) error {
	cfg, err := loadMenuConfig(path)
	if err != nil {
		return err
	}
	fmt.Printf("Listen: %s\nBase path: %s\nAPI token: %s\nTLS certificate: %s\n", cfg.Listen, cfg.BasePath, cfg.Token, cfg.TLSCert)
	fmt.Println("认证方式: Bearer Token（没有账号密码）")
	return showFingerprint(cfg.TLSCert)
}

func changeMenuPort(reader *bufio.Reader, path string) error {
	cfg, err := loadMenuConfig(path)
	if err != nil {
		return err
	}
	fmt.Print("请输入 API 端口（1-65535）: ")
	value, err := readMenuLine(reader)
	if err != nil {
		return err
	}
	port, err := strconv.Atoi(value)
	if err != nil || port < 1 || port > 65535 {
		return fmt.Errorf("端口必须是 1-65535")
	}
	host, _, splitErr := net.SplitHostPort(cfg.Listen)
	if splitErr != nil {
		host = ""
	}
	cfg.Listen = net.JoinHostPort(host, strconv.Itoa(port))
	return saveMenuConfigAndRestart(path, cfg)
}

func changeMenuBasePath(reader *bufio.Reader, path string) error {
	cfg, err := loadMenuConfig(path)
	if err != nil {
		return err
	}
	fmt.Printf("请输入访问路径（例如 /panel，当前 %s）: ", cfg.BasePath)
	value, err := readMenuLine(reader)
	if err != nil {
		return err
	}
	cfg.BasePath, err = normalizeMenuBasePath(value)
	if err != nil {
		return err
	}
	return saveMenuConfigAndRestart(path, cfg)
}

func normalizeMenuBasePath(value string) (string, error) {
	if strings.ContainsAny(value, "\r\n\x00") || strings.IndexFunc(value, func(r rune) bool {
		return r == ' ' || r == '\t'
	}) >= 0 {
		return "", fmt.Errorf("访问路径包含非法字符")
	}
	value = strings.TrimSpace(value)
	if value == "" {
		return "", fmt.Errorf("访问路径不能为空")
	}
	if !strings.HasPrefix(value, "/") {
		return "", fmt.Errorf("访问路径必须以 / 开头")
	}
	if value == "/" {
		return value, nil
	}
	return "/" + strings.Trim(pathpkg.Clean(value), "/") + "/", nil
}

func resetMenuToken(path string) error {
	cfg, err := loadMenuConfig(path)
	if err != nil {
		return err
	}
	token := make([]byte, 32)
	if _, err = rand.Read(token); err != nil {
		return err
	}
	cfg.Token = hex.EncodeToString(token)
	return saveMenuConfigAndRestart(path, cfg)
}

func saveMenuConfigAndRestart(path string, cfg node.Config) error {
	previous, err := os.ReadFile(path)
	if err != nil {
		return err
	}
	if err = writeMenuConfig(path, cfg); err != nil {
		return err
	}
	if err = restartNodeService(); err != nil {
		_ = atomicWriteMenuFile(path, previous)
		return fmt.Errorf("配置已回滚，服务重启失败: %w", err)
	}
	fmt.Println("配置已保存，服务已重启。")
	return nil
}

func writeMenuConfig(path string, cfg node.Config) error {
	b, err := json.MarshalIndent(cfg, "", "  ")
	if err != nil {
		return err
	}
	return atomicWriteMenuFile(path, append(b, '\n'))
}

func atomicWriteMenuFile(path string, data []byte) error {
	dir := pathpkg.Dir(path)
	temp, err := os.CreateTemp(dir, ".config.json.*")
	if err != nil {
		return err
	}
	tempPath := temp.Name()
	defer os.Remove(tempPath)
	if err = temp.Chmod(0600); err == nil {
		_, err = temp.Write(data)
	}
	if err == nil {
		err = temp.Sync()
	}
	closeErr := temp.Close()
	if err == nil {
		err = closeErr
	}
	if err != nil {
		return err
	}
	return os.Rename(tempPath, path)
}

func restartNodeService() error {
	if _, err := exec.LookPath("systemctl"); err == nil {
		return exec.Command("systemctl", "restart", "angelo-node.service").Run()
	}
	if _, err := exec.LookPath("rc-service"); err == nil {
		return exec.Command("rc-service", "angelo-node", "restart").Run()
	}
	return fmt.Errorf("未找到 systemctl 或 rc-service")
}
