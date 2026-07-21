//go:build linux

package main

import (
	"context"
	"io"
	"os"
	"strconv"
	"strings"
	"syscall"
	"testing"
	"time"
)

func TestWebSocketPTYCleanupTerminatesEverySessionProcessGroup(t *testing.T) {
	tests := []struct {
		name   string
		close  func(*testing.T, *wsPTYHub, *wsPTYAttachment)
		idleTT time.Duration
	}{
		{
			name: "explicit close",
			close: func(t *testing.T, hub *wsPTYHub, attachment *wsPTYAttachment) {
				if !hub.closeSessionByID(attachment.sessionKey.sessionID) {
					t.Fatal("closeSessionByID returned false")
				}
			},
		},
		{
			name: "server closeAll",
			close: func(_ *testing.T, hub *wsPTYHub, _ *wsPTYAttachment) {
				hub.closeAll()
			},
		},
		{
			name:   "idle reap",
			idleTT: 20 * time.Millisecond,
			close: func(t *testing.T, hub *wsPTYHub, attachment *wsPTYAttachment) {
				if !hub.detach(attachment) {
					t.Fatal("detach returned false")
				}
				waitForHubSessionCount(t, hub, 0, 5*time.Second)
			},
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			hub := newWebSocketPTYHub(wsPTYServerConfig{
				Shell:          "/bin/sh",
				SessionIdleTTL: test.idleTT,
			}, io.Discard)
			if test.idleTT == 0 {
				hub.sessionIdleTTL = time.Hour
			}

			sessionID := "cleanup-" + strings.ReplaceAll(test.name, " ", "-")
			attachment, _, _, err := hub.prepareAttachment(
				context.Background(),
				nil,
				sessionID,
				"attachment",
				80,
				24,
				true,
				`set -m; trap '' HUP; sleep 300 & wait`,
				"token",
				false,
				false,
			)
			if err != nil {
				t.Fatalf("prepare PTY session: %v", err)
			}

			hub.mu.Lock()
			session := hub.sessions[persistentPTYSessionKey(sessionID)]
			leaderPID := session.cmd.Process.Pid
			hub.mu.Unlock()

			backgroundPIDs := waitForLinuxSessionBackgroundGroup(t, leaderPID, 5*time.Second)
			t.Cleanup(func() {
				for _, pid := range backgroundPIDs {
					_ = syscall.Kill(pid, syscall.SIGKILL)
				}
				_ = syscall.Kill(-leaderPID, syscall.SIGKILL)
				hub.closeAll()
			})

			test.close(t, hub, attachment)
			waitForLinuxProcessesStopped(t, backgroundPIDs, 5*time.Second)
		})
	}
}

func TestWebSocketPTYLeaderExitTerminatesEverySessionProcessGroup(t *testing.T) {
	hub := newWebSocketPTYHub(wsPTYServerConfig{
		Shell:          "/bin/sh",
		SessionIdleTTL: time.Hour,
	}, io.Discard)
	t.Cleanup(hub.closeAll)

	const sessionID = "leader-exit-cleanup"
	_, _, _, err := hub.prepareAttachment(
		context.Background(),
		nil,
		sessionID,
		"attachment",
		80,
		24,
		true,
		`set -m; sleep 300 & exit 0`,
		"token",
		false,
		false,
	)
	if err != nil {
		t.Fatalf("prepare PTY session: %v", err)
	}

	hub.mu.Lock()
	session := hub.sessions[persistentPTYSessionKey(sessionID)]
	if session == nil || session.cmd == nil || session.cmd.Process == nil {
		hub.mu.Unlock()
		t.Fatal("persistent PTY session has no leader process")
	}
	leaderPID := session.cmd.Process.Pid
	hub.mu.Unlock()

	backgroundPIDs := waitForLinuxSessionBackgroundGroup(t, leaderPID, 5*time.Second)
	t.Cleanup(func() {
		for _, pid := range backgroundPIDs {
			_ = syscall.Kill(pid, syscall.SIGKILL)
		}
		_ = syscall.Kill(-leaderPID, syscall.SIGKILL)
	})

	waitForHubSessionCount(t, hub, 0, time.Second)
	waitForLinuxProcessesStopped(t, backgroundPIDs, 5*time.Second)
}

type linuxSessionProcess struct {
	pid     int
	groupID int
	state   byte
}

func waitForLinuxSessionBackgroundGroup(t *testing.T, sessionID int, timeout time.Duration) []int {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		var backgroundPIDs []int
		for _, process := range linuxSessionProcesses(t, sessionID) {
			if process.groupID != sessionID && process.state != 'Z' {
				backgroundPIDs = append(backgroundPIDs, process.pid)
			}
		}
		if len(backgroundPIDs) > 0 {
			return backgroundPIDs
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("PTY session %d did not create a background process group", sessionID)
	return nil
}

func waitForLinuxProcessesStopped(t *testing.T, pids []int, timeout time.Duration) {
	t.Helper()
	deadline := time.Now().Add(timeout)
	for time.Now().Before(deadline) {
		allStopped := true
		for _, pid := range pids {
			process, ok := readLinuxSessionProcess(pid)
			if ok && process.state != 'Z' {
				allStopped = false
				break
			}
		}
		if allStopped {
			return
		}
		time.Sleep(10 * time.Millisecond)
	}
	t.Fatalf("background PTY session processes still running after cleanup: %v", pids)
}

func linuxSessionProcesses(t *testing.T, sessionID int) []linuxSessionProcess {
	t.Helper()
	entries, err := os.ReadDir("/proc")
	if err != nil {
		t.Fatalf("read /proc: %v", err)
	}
	processes := make([]linuxSessionProcess, 0)
	for _, entry := range entries {
		pid, err := strconv.Atoi(entry.Name())
		if err != nil {
			continue
		}
		process, ok := readLinuxSessionProcess(pid)
		if ok && linuxTestProcessSessionID(pid) == sessionID {
			processes = append(processes, process)
		}
	}
	return processes
}

func linuxTestProcessSessionID(pid int) int {
	data, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/stat")
	if err != nil {
		return 0
	}
	fields := linuxProcessStatFields(data)
	if len(fields) < 4 {
		return 0
	}
	sessionID, _ := strconv.Atoi(fields[3])
	return sessionID
}

func readLinuxSessionProcess(pid int) (linuxSessionProcess, bool) {
	data, err := os.ReadFile("/proc/" + strconv.Itoa(pid) + "/stat")
	if err != nil {
		return linuxSessionProcess{}, false
	}
	fields := linuxProcessStatFields(data)
	if len(fields) < 4 || len(fields[0]) != 1 {
		return linuxSessionProcess{}, false
	}
	groupID, err := strconv.Atoi(fields[2])
	if err != nil {
		return linuxSessionProcess{}, false
	}
	return linuxSessionProcess{pid: pid, groupID: groupID, state: fields[0][0]}, true
}

func linuxProcessStatFields(data []byte) []string {
	closingParen := strings.LastIndexByte(string(data), ')')
	if closingParen < 0 || closingParen+2 >= len(data) {
		return nil
	}
	return strings.Fields(string(data[closingParen+2:]))
}
