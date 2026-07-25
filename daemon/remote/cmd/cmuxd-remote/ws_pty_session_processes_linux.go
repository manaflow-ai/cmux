//go:build linux

package main

import (
	"os"
	"strconv"
	"strings"
)

func ptySessionMemberPIDs(sessionID int) []int {
	entries, err := os.ReadDir("/proc")
	if err != nil {
		return nil
	}
	members := make([]int, 0)
	for _, entry := range entries {
		pid, err := strconv.Atoi(entry.Name())
		if err != nil {
			continue
		}
		data, err := os.ReadFile("/proc/" + entry.Name() + "/stat")
		if err != nil {
			continue
		}
		closingParen := strings.LastIndexByte(string(data), ')')
		if closingParen < 0 || closingParen+2 >= len(data) {
			continue
		}
		fields := strings.Fields(string(data[closingParen+2:]))
		if len(fields) < 4 || fields[0] == "Z" {
			continue
		}
		processSessionID, err := strconv.Atoi(fields[3])
		if err == nil && processSessionID == sessionID {
			members = append(members, pid)
		}
	}
	return members
}
