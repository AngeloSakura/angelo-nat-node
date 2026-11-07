package node

import (
	"bytes"
	"context"
	"fmt"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"sync"
	"time"
)

type boundedLog struct {
	mu   sync.Mutex
	data []byte
}

func (b *boundedLog) Write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	b.data = append(b.data, p...)
	if len(b.data) > 4096 {
		b.data = b.data[len(b.data)-4096:]
	}
	return len(p), nil
}
func (b *boundedLog) String() string { b.mu.Lock(); defer b.mu.Unlock(); return string(b.data) }

type Process struct {
	cfg     Config
	cmd     *exec.Cmd
	done    chan error
	stats   *statsClient
	version string
	config  []byte
	log     *boundedLog
}

func NewProcess(cfg Config) (*Process, error) {
	if !filepath.IsAbs(cfg.XrayPath) {
		return nil, fmt.Errorf("xrayPath must be absolute")
	}
	ctx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
	defer cancel()
	out, err := exec.CommandContext(ctx, cfg.XrayPath, "version").Output()
	if err != nil {
		return nil, fmt.Errorf("Xray version: %w", err)
	}
	fields := strings.Fields(string(out))
	version := "unknown"
	if len(fields) > 1 {
		version = fields[1]
	}
	return &Process{cfg: cfg, stats: newStatsClient(cfg.APIAddress), version: version}, nil
}
func (p *Process) Running() bool {
	if p.cmd == nil {
		return false
	}
	select {
	case <-p.done:
		p.cmd = nil
		return false
	default:
		return true
	}
}
func (p *Process) Version() string                                     { return p.version }
func (p *Process) Stats(ctx context.Context) (map[string]int64, error) { return p.stats.query(ctx) }
func (p *Process) Stop() error {
	if !p.Running() {
		return nil
	}
	p.stats.transport.CloseIdleConnections()
	_ = p.cmd.Process.Signal(os.Interrupt)
	select {
	case <-p.done:
	case <-time.After(500 * time.Millisecond):
		_ = p.cmd.Process.Kill()
		<-p.done
	}
	p.cmd = nil
	return nil
}
func (p *Process) Apply(ctx context.Context, data []byte) error {
	ctx, cancel := context.WithTimeout(ctx, 3*time.Second)
	defer cancel()
	old := bytes.Clone(p.config)
	_ = p.Stop()
	if err := p.launch(ctx, data); err != nil {
		_ = p.Stop()
		if len(old) > 0 {
			rollbackCtx, cancel := context.WithTimeout(context.Background(), 3*time.Second)
			defer cancel()
			if rollback := p.launch(rollbackCtx, old); rollback != nil {
				return fmt.Errorf("apply failed: %v; rollback failed: %v", err, rollback)
			}
		}
		return err
	}
	p.config = bytes.Clone(data)
	return nil
}
func (p *Process) launch(ctx context.Context, data []byte) error {
	configPath := filepath.Join(p.cfg.StateDir, "xray.json")
	if err := atomicWrite(configPath, data, 0600); err != nil {
		return err
	}
	// Only one Xray process exists at a time, including configuration validation.
	checkCtx, cancel := context.WithTimeout(ctx, 2*time.Second)
	check := exec.CommandContext(checkCtx, p.cfg.XrayPath, "run", "-test", "-config", configPath)
	configureChild(check)
	output := &boundedLog{}
	check.Stdout = output
	check.Stderr = output
	check.Env = p.environment()
	err := check.Run()
	cancel()
	if err != nil {
		return fmt.Errorf("Xray config rejected: %v: %s", err, output.String())
	}
	p.log = &boundedLog{}
	p.cmd = exec.Command(p.cfg.XrayPath, "run", "-config", configPath)
	configureChild(p.cmd)
	p.cmd.Env = p.environment()
	p.cmd.Stdout = p.log
	p.cmd.Stderr = p.log
	if err = p.cmd.Start(); err != nil {
		p.cmd = nil
		return err
	}
	p.done = make(chan error, 1)
	cmd, done := p.cmd, p.done
	go func() { done <- cmd.Wait() }()
	for {
		if !p.Running() {
			return fmt.Errorf("Xray exited: %s", p.log.String())
		}
		readyCtx, cancel := context.WithTimeout(ctx, 200*time.Millisecond)
		_, err = p.stats.query(readyCtx)
		cancel()
		if err == nil {
			return nil
		}
		select {
		case <-ctx.Done():
			return fmt.Errorf("Xray API not ready: %w; last query: %v; log: %s", ctx.Err(), err, p.log.String())
		case <-time.After(30 * time.Millisecond):
		}
	}
}
func (p *Process) environment() []string {
	env := []string{}
	for _, v := range os.Environ() {
		if !strings.HasPrefix(v, "GOMEMLIMIT=") && !strings.HasPrefix(v, "GOGC=") && !strings.HasPrefix(v, "GOMAXPROCS=") {
			env = append(env, v)
		}
	}
	limit := p.cfg.XrayMemoryLimit
	if limit == "" {
		limit = "24MiB"
	}
	return append(env, "GOMEMLIMIT="+limit, "GOGC=50", "GOMAXPROCS=1", "XRAY_LOCATION_ASSET="+filepath.Dir(p.cfg.XrayPath))
}
