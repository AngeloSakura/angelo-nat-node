package main

import (
	"fmt"
	"os"
	"syscall"
)

func lockXrayUpdate(path string) (func(), error) {
	f, err := os.OpenFile(path, os.O_CREATE|os.O_RDWR, 0600)
	if err != nil {
		return nil, err
	}
	if err = syscall.Flock(int(f.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		f.Close()
		return nil, fmt.Errorf("已有节点或内核更新正在进行: %w", err)
	}
	return func() { f.Close() }, nil
}
