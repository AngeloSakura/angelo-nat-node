package node

import (
	"bufio"
	"os"
	"strconv"
	"strings"
)

func memoryUsage() (uint64, uint64) {
	f, err := os.Open("/proc/meminfo")
	if err != nil {
		return 0, 0
	}
	defer f.Close()
	values := map[string]uint64{}
	scan := bufio.NewScanner(f)
	for scan.Scan() {
		parts := strings.Fields(scan.Text())
		if len(parts) > 1 {
			n, _ := strconv.ParseUint(parts[1], 10, 64)
			values[strings.TrimSuffix(parts[0], ":")] = n * 1024
		}
	}
	total := values["MemTotal"]
	available := values["MemAvailable"]
	if available > total {
		return 0, total
	}
	return total - available, total
}

var Version = "dev"
