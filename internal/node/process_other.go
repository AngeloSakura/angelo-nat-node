//go:build !linux

package node

import "os/exec"

func configureChild(cmd *exec.Cmd) {}
