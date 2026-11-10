package main

import (
	"archive/zip"
	"bufio"
	"context"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"time"
)

const xrayReleaseAPI = "https://api.github.com/repos/XTLS/Xray-core/releases"
const maxXrayArchive = 96 << 20
const maxXrayBinary = 128 << 20

type xrayAsset struct {
	Name   string `json:"name"`
	URL    string `json:"browser_download_url"`
	Digest string `json:"digest"`
}
type xrayRelease struct {
	Tag        string      `json:"tag_name"`
	Draft      bool        `json:"draft"`
	Prerelease bool        `json:"prerelease"`
	Assets     []xrayAsset `json:"assets"`
}

// Match the version floor used by 3x-ui's GetXrayVersions.
func supportedXrayTag(tag string) bool {
	if !regexp.MustCompile(`^v[0-9]+\.[0-9]+\.[0-9]+$`).MatchString(tag) {
		return false
	}
	parts := strings.Split(strings.TrimPrefix(tag, "v"), ".")
	n := [3]int{}
	for i, s := range parts {
		v, err := strconv.Atoi(s)
		if err != nil {
			return false
		}
		n[i] = v
	}
	return n[0] > 26 || n[0] == 26 && (n[1] > 6 || n[1] == 6 && n[2] >= 27)
}
func xrayAssetName(arch string) (string, error) {
	names := map[string]string{"amd64": "Xray-linux-64.zip", "arm64": "Xray-linux-arm64-v8a.zip", "386": "Xray-linux-32.zip", "arm": "Xray-linux-arm32-v7a.zip"}
	if name, ok := names[arch]; ok {
		return name, nil
	}
	return "", fmt.Errorf("不支持的架构: %s", arch)
}
func releaseAsset(r xrayRelease, name string) (xrayAsset, bool) {
	for _, a := range r.Assets {
		if a.Name == name {
			return a, true
		}
	}
	return xrayAsset{}, false
}
func xrayHTTPClient() *http.Client {
	return &http.Client{Timeout: 3 * time.Minute, CheckRedirect: func(req *http.Request, via []*http.Request) error {
		if len(via) >= 8 || req.URL.Scheme != "https" {
			return fmt.Errorf("拒绝不安全的下载重定向")
		}
		return nil
	}}
}
func fetchXrayReleases(ctx context.Context, client *http.Client, endpoint, asset string) ([]xrayRelease, error) {
	ctx, cancel := context.WithTimeout(ctx, 20*time.Second)
	defer cancel()
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, endpoint, nil)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Accept", "application/vnd.github+json")
	req.Header.Set("User-Agent", "angelo-nat-node")
	resp, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return nil, fmt.Errorf("获取 Xray 版本列表失败: HTTP %d（请检查网络或 GitHub API 限额）", resp.StatusCode)
	}
	data, err := io.ReadAll(io.LimitReader(resp.Body, (4<<20)+1))
	if err != nil {
		return nil, err
	}
	if len(data) > 4<<20 {
		return nil, fmt.Errorf("版本列表过大")
	}
	var all []xrayRelease
	if err = json.Unmarshal(data, &all); err != nil {
		return nil, err
	}
	var releases []xrayRelease
	seen := map[string]bool{}
	for _, r := range all {
		if _, ok := releaseAsset(r, asset); !r.Draft && supportedXrayTag(r.Tag) && ok && !seen[r.Tag] {
			releases = append(releases, r)
			seen[r.Tag] = true
		}
	}
	if len(releases) == 0 {
		return nil, fmt.Errorf("没有适用于本机的 Xray 版本")
	}
	return releases, nil
}
func chooseXrayRelease(reader *bufio.Reader, out io.Writer, releases []xrayRelease, current string) (*xrayRelease, error) {
	fmt.Fprintf(out, "当前 Xray: %s\n可选版本（与 3x-ui 同源：XTLS 官方 Releases）：\n", current)
	for i, r := range releases {
		label := ""
		if r.Prerelease {
			label += " [预发布]"
		}
		if strings.TrimPrefix(r.Tag, "v") == strings.TrimPrefix(current, "v") {
			label += " [当前]"
		}
		fmt.Fprintf(out, "%d. %s%s\n", i+1, r.Tag, label)
	}
	for {
		fmt.Fprint(out, "请选择版本序号（0 返回）: ")
		value, err := readMenuLine(reader)
		if err != nil {
			return nil, err
		}
		if value == "0" {
			return nil, nil
		}
		index, err := strconv.Atoi(value)
		if err != nil || index < 1 || index > len(releases) {
			fmt.Fprintln(out, "无效序号，请重新选择。")
			continue
		}
		return &releases[index-1], nil
	}
}
func validXrayDownload(raw, tag, name string) bool {
	u, err := url.Parse(raw)
	return err == nil && u.Scheme == "https" && u.Host == "github.com" && u.User == nil && u.RawQuery == "" && u.Fragment == "" && u.Path == "/XTLS/Xray-core/releases/download/"+tag+"/"+name
}
func downloadXrayFile(ctx context.Context, client *http.Client, raw, path string, limit int64) error {
	req, err := http.NewRequestWithContext(ctx, http.MethodGet, raw, nil)
	if err != nil {
		return err
	}
	resp, err := client.Do(req)
	if err != nil {
		return err
	}
	defer resp.Body.Close()
	if resp.StatusCode != 200 {
		return fmt.Errorf("下载失败: HTTP %d", resp.StatusCode)
	}
	f, err := os.OpenFile(path, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0600)
	if err != nil {
		return err
	}
	n, copyErr := io.Copy(f, io.LimitReader(resp.Body, limit+1))
	syncErr := f.Sync()
	closeErr := f.Close()
	if copyErr != nil {
		return copyErr
	}
	if n > limit {
		return fmt.Errorf("下载文件超过大小限制")
	}
	return errors.Join(syncErr, closeErr)
}
func xraySHA256(digest string) (string, error) {
	value := strings.TrimPrefix(digest, "sha256:")
	if len(value) != 64 {
		return "", fmt.Errorf("缺少有效的官方 SHA256")
	}
	if _, err := hex.DecodeString(value); err != nil {
		return "", fmt.Errorf("无效的官方 SHA256")
	}
	return strings.ToLower(value), nil
}
func prepareXray(ctx context.Context, client *http.Client, r xrayRelease, assetName, stage string) (string, error) {
	a, ok := releaseAsset(r, assetName)
	if !ok || !validXrayDownload(a.URL, r.Tag, assetName) {
		return "", fmt.Errorf("发布资产无效")
	}
	archive := filepath.Join(stage, "xray.zip")
	if err := downloadXrayFile(ctx, client, a.URL, archive, maxXrayArchive); err != nil {
		return "", err
	}
	digest, err := xraySHA256(a.Digest)
	if err != nil {
		// Older releases may not expose asset.digest; use their .dgst asset.
		checksum, ok := releaseAsset(r, assetName+".dgst")
		if !ok || !validXrayDownload(checksum.URL, r.Tag, checksum.Name) {
			return "", err
		}
		path := filepath.Join(stage, "xray.dgst")
		if err = downloadXrayFile(ctx, client, checksum.URL, path, 16<<10); err != nil {
			return "", err
		}
		data, readErr := os.ReadFile(path)
		if readErr != nil {
			return "", readErr
		}
		matches := regexp.MustCompile(`(?im)^SHA2?-?256\s*\([^\r\n]*\)\s*=\s*([a-f0-9]{64})\s*$`).FindAllSubmatch(data, -1)
		if len(matches) != 1 {
			return "", fmt.Errorf("官方校验文件缺少唯一 SHA256")
		}
		digest = strings.ToLower(string(matches[0][1]))
	}
	f, err := os.Open(archive)
	if err != nil {
		return "", err
	}
	hash := sha256.New()
	_, err = io.Copy(hash, f)
	f.Close()
	if err != nil {
		return "", err
	}
	if hex.EncodeToString(hash.Sum(nil)) != digest {
		return "", fmt.Errorf("Xray 下载文件 SHA256 校验失败")
	}
	return extractXray(archive, filepath.Join(stage, "xray"))
}
func extractXray(archive, destination string) (string, error) {
	z, err := zip.OpenReader(archive)
	if err != nil {
		return "", err
	}
	defer z.Close()
	var entry *zip.File
	for _, f := range z.File {
		if f.Name == "xray" {
			if entry != nil || !f.Mode().IsRegular() || f.UncompressedSize64 > maxXrayBinary {
				return "", fmt.Errorf("Xray 压缩包包含无效或重复的可执行文件")
			}
			entry = f
		}
	}
	if entry == nil {
		return "", fmt.Errorf("Xray 压缩包缺少可执行文件")
	}
	source, err := entry.Open()
	if err != nil {
		return "", err
	}
	defer source.Close()
	target, err := os.OpenFile(destination, os.O_WRONLY|os.O_CREATE|os.O_EXCL, 0700)
	if err != nil {
		return "", err
	}
	n, copyErr := io.Copy(target, io.LimitReader(source, maxXrayBinary+1))
	syncErr := target.Sync()
	closeErr := target.Close()
	if copyErr != nil {
		return "", copyErr
	}
	if n == 0 || n > maxXrayBinary {
		return "", fmt.Errorf("Xray 可执行文件大小无效")
	}
	return destination, errors.Join(syncErr, closeErr)
}
