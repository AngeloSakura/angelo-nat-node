package main

import (
	"context"
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/tls"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"flag"
	"fmt"
	"log"
	"math/big"
	"net"
	"net/http"
	"os"
	"os/signal"
	"path/filepath"
	"runtime"
	"runtime/debug"
	"strings"
	"syscall"
	"time"

	"github.com/AngeloSakura/angelo-nat-node/internal/node"
	"golang.org/x/net/netutil"
)

func main() {
	if err := run(); err != nil {
		log.Fatal(err)
	}
}
func run() error {
	configPath := flag.String("config", "/etc/angelo-node/config.json", "configuration file")
	initialize := flag.Bool("init", false, "create config, token and TLS certificate; never overwrite existing files")
	show := flag.Bool("show", false, "show connection parameters (includes secret token)")
	check := flag.Bool("check", false, "validate config and saved state without starting Xray")
	statePath := flag.Bool("state-dir-path", false, "print configured absolute persistent state directory")
	health := flag.Bool("health-check", false, "check authenticated local API and running Xray")
	version := flag.Bool("version", false, "print version")
	listen := flag.String("listen", ":2053", "initial API listen address")
	basePath := flag.String("base-path", "/", "initial API path suffix")
	xray := flag.String("xray", "/usr/local/lib/angelo-node/xray", "initial original Xray path")
	stateDir := flag.String("state-dir", "/var/lib/angelo-node", "initial persistent state directory")
	flag.Parse()
	if len(os.Args) == 1 {
		return runInteractiveMenu(*configPath)
	}
	if *version {
		fmt.Println(node.Version)
		return nil
	}
	if *initialize {
		return initConfig(*configPath, *listen, *basePath, *xray, *stateDir)
	}
	b, err := os.ReadFile(*configPath)
	if err != nil {
		return err
	}
	var cfg node.Config
	if err = json.Unmarshal(b, &cfg); err != nil {
		return err
	}
	if cfg.APIAddress == "" {
		cfg.APIAddress = "127.0.0.1:10085"
	}
	if cfg.Listen == "" {
		return fmt.Errorf("listen is required")
	}
	if !strings.HasPrefix(cfg.BasePath, "/") {
		return fmt.Errorf("basePath must begin with /")
	}
	if *show {
		fmt.Printf("Listen: %s\nBase path: %s\nAPI token: %s\nTLS certificate: %s\n", cfg.Listen, cfg.BasePath, cfg.Token, cfg.TLSCert)
		return showFingerprint(cfg.TLSCert)
	}
	if *statePath {
		if !filepath.IsAbs(cfg.StateDir) || strings.ContainsAny(cfg.StateDir, "\r\n\x00") {
			return fmt.Errorf("invalid absolute stateDir")
		}
		fmt.Println(cfg.StateDir)
		return nil
	}
	if *health {
		return healthCheck(cfg)
	}
	if *check {
		err = node.Check(cfg)
		if err == nil {
			fmt.Println("Configuration and state OK")
		}
		return err
	}
	if os.Getenv("GOMEMLIMIT") == "" {
		debug.SetMemoryLimit(12 << 20)
	}
	if os.Getenv("GOGC") == "" {
		debug.SetGCPercent(50)
	}
	if os.Getenv("GOMAXPROCS") == "" {
		runtime.GOMAXPROCS(1)
	}
	core, err := node.NewProcess(cfg)
	if err != nil {
		return err
	}
	app, err := node.Open(cfg, core)
	if err != nil {
		return err
	}
	ctx, stop := signal.NotifyContext(context.Background(), os.Interrupt, syscall.SIGTERM)
	defer stop()
	startCtx, cancel := context.WithTimeout(ctx, 8*time.Second)
	err = app.Start(startCtx)
	cancel()
	if err != nil {
		_ = core.Stop()
		return err
	}
	defer app.Close()
	server := &http.Server{Addr: cfg.Listen, Handler: app, ReadHeaderTimeout: 3 * time.Second, ReadTimeout: 5 * time.Second, WriteTimeout: 10 * time.Second, IdleTimeout: 15 * time.Second, MaxHeaderBytes: 8192}
	// Bound TLS sessions and prevent HTTP/2 multiplexing from bypassing it.
	server.TLSNextProto = map[string]func(*http.Server, *tls.Conn, http.Handler){}
	listener, err := net.Listen("tcp", cfg.Listen)
	if err != nil {
		return err
	}
	listener = netutil.LimitListener(listener, 8)
	defer listener.Close()
	go app.Run(ctx)
	result := make(chan error, 1)
	go func() {
		if cfg.TLSCert != "" && cfg.TLSKey != "" {
			result <- server.ServeTLS(listener, cfg.TLSCert, cfg.TLSKey)
		} else {
			result <- server.Serve(listener)
		}
	}()
	log.Printf("angelo-node %s listening on %s; Xray %s", node.Version, cfg.Listen, core.Version())
	select {
	case <-ctx.Done():
		shutdown, cancel := context.WithTimeout(context.Background(), 10*time.Second)
		defer cancel()
		return server.Shutdown(shutdown)
	case err = <-result:
		stop()
		if err == http.ErrServerClosed {
			return nil
		}
		return err
	}
}
func initConfig(path, listen, basePath, xray, stateDir string) error {
	normalizedBasePath, err := normalizeMenuBasePath(basePath)
	if err != nil {
		return fmt.Errorf("invalid API base path: %w", err)
	}
	basePath = normalizedBasePath
	if _, err := os.Stat(path); err == nil {
		return fmt.Errorf("config already exists; refusing to regenerate token or overwrite users")
	} else if !os.IsNotExist(err) {
		return err
	}
	directory := filepath.Dir(path)
	if err := os.MkdirAll(directory, 0700); err != nil {
		return err
	}
	secret := make([]byte, 32)
	if _, err := rand.Read(secret); err != nil {
		return err
	}
	certPath, keyPath := filepath.Join(directory, "tls.crt"), filepath.Join(directory, "tls.key")
	if err := selfSigned(certPath, keyPath); err != nil {
		return err
	}
	cfg := node.Config{Listen: listen, Token: hex.EncodeToString(secret), BasePath: basePath, StateDir: stateDir, XrayPath: xray, APIAddress: "127.0.0.1:10085", TLSCert: certPath, TLSKey: keyPath, PollSeconds: 10, MaxClients: 64, MaxInbounds: 16, XrayMemoryLimit: "24MiB"}
	b, _ := json.MarshalIndent(cfg, "", "  ")
	if err := writeNew(path, b); err != nil {
		return err
	}
	fmt.Printf("Created %s. API listen: %s. API base path: %s.\n", path, cfg.Listen, cfg.BasePath)
	return nil
}
func writeNew(path string, b []byte) error {
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return err
	}
	_, err = f.Write(b)
	if err == nil {
		err = f.Sync()
	}
	closeErr := f.Close()
	if err != nil {
		return err
	}
	return closeErr
}
func selfSigned(certPath, keyPath string) error {
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		return err
	}
	serial, err := rand.Int(rand.Reader, new(big.Int).Lsh(big.NewInt(1), 128))
	if err != nil {
		return err
	}
	template := x509.Certificate{SerialNumber: serial, Subject: pkix.Name{CommonName: "angelo-node"}, NotBefore: time.Now().Add(-time.Hour), NotAfter: time.Now().AddDate(3, 0, 0), KeyUsage: x509.KeyUsageDigitalSignature, ExtKeyUsage: []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth}, DNSNames: []string{"localhost", "angelo-node"}, IPAddresses: []net.IP{net.ParseIP("127.0.0.1"), net.ParseIP("::1")}}
	der, err := x509.CreateCertificate(rand.Reader, &template, &template, &key.PublicKey, key)
	if err != nil {
		return err
	}
	private, err := x509.MarshalPKCS8PrivateKey(key)
	if err != nil {
		return err
	}
	if err = writeNew(keyPath, pem.EncodeToMemory(&pem.Block{Type: "PRIVATE KEY", Bytes: private})); err != nil {
		return err
	}
	return writeNew(certPath, pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}))
}
