//go:build !linux

package main

import "fmt"

func lockXrayUpdate(string) (func(), error) {
	return nil, fmt.Errorf("切换内核仅支持 Linux")
}
