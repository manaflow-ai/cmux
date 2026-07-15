package main

import (
	"bufio"
	"bytes"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

var processStartTime = time.Now()

const daemonStatusProbeTimeout = 5 * time.Second

func (s *rpcServer) handleDaemonStatus(req rpcRequest) rpcResponse {
	uptimeSeconds := int64(time.Since(processStartTime) / time.Second)
	if uptimeSeconds < 0 {
		uptimeSeconds = 0
	}
	ptySessions := 0
	if s.ptyHub != nil {
		ptySessions = s.ptyHub.activeSessionCount()
	}
	return rpcResponse{
		ID: req.ID,
		OK: true,
		Result: map[string]any{
			"name":            "cmuxd-remote",
			"version":         version,
			"pid":             os.Getpid(),
			"started_at_unix": processStartTime.Unix(),
			"uptime_seconds":  uptimeSeconds,
			"pty_sessions":    ptySessions,
		},
	}
}

type daemonStatusEntry struct {
	VersionDir    string `json:"version_dir"`
	Running       bool   `json:"running"`
	Socket        string `json:"socket,omitempty"`
	PID           int    `json:"pid,omitempty"`
	Version       string `json:"version,omitempty"`
	StartedAtUnix int64  `json:"started_at_unix,omitempty"`
	UptimeSeconds *int64 `json:"uptime_seconds,omitempty"`
	PTYSessions   *int   `json:"pty_sessions,omitempty"`
	Error         string `json:"error,omitempty"`
}

type daemonStatusOutput struct {
	BinaryVersion string              `json:"binary_version"`
	Slot          string              `json:"slot"`
	Root          string              `json:"root"`
	Daemons       []daemonStatusEntry `json:"daemons"`
}

func runDaemonStatusCommand(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("daemon-status", flag.ContinueOnError)
	fs.SetOutput(stderr)
	slotFlag := fs.String("slot", "", "persistent daemon slot")
	jsonFlag := fs.Bool("json", false, "emit JSON output")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if fs.NArg() > 0 {
		_, _ = fmt.Fprintf(stderr, "daemon-status does not accept positional arguments: %q\n", fs.Args())
		return 2
	}
	slot, err := validatePersistentDaemonSlot(*slotFlag)
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "daemon-status requires --slot: %v\n", err)
		return 2
	}
	rootBase, err := persistentDaemonRootBase()
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "daemon-status failed: %v\n", err)
		return 1
	}
	output, err := collectDaemonStatus(rootBase, slot)
	if err != nil {
		_, _ = fmt.Fprintf(stderr, "daemon-status failed: %v\n", err)
		return 1
	}
	if *jsonFlag {
		data, err := json.Marshal(output)
		if err != nil {
			_, _ = fmt.Fprintf(stderr, "daemon-status failed: %v\n", err)
			return 1
		}
		_, _ = fmt.Fprintln(stdout, string(data))
		return 0
	}
	writeDaemonStatusText(stdout, output)
	return 0
}

func collectDaemonStatus(rootBase string, slot string) (daemonStatusOutput, error) {
	output := daemonStatusOutput{
		BinaryVersion: version,
		Slot:          slot,
		Root:          rootBase,
		Daemons:       []daemonStatusEntry{},
	}
	entries, err := os.ReadDir(rootBase)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return output, nil
		}
		return output, err
	}
	versionDirs := make([]string, 0, len(entries))
	for _, entry := range entries {
		if !entry.IsDir() {
			continue
		}
		slotInfo, statErr := os.Stat(filepath.Join(rootBase, entry.Name(), slot))
		if statErr != nil || !slotInfo.IsDir() {
			continue
		}
		versionDirs = append(versionDirs, entry.Name())
	}
	sort.Strings(versionDirs)
	for _, versionDir := range versionDirs {
		output.Daemons = append(output.Daemons, probeDaemonStatus(rootBase, versionDir, slot))
	}
	return output, nil
}

func probeDaemonStatus(rootBase string, versionDir string, slot string) daemonStatusEntry {
	entry := daemonStatusEntry{VersionDir: versionDir}
	root := filepath.Join(rootBase, versionDir, slot)
	paths := persistentDaemonPathsForRoot(root, slot)
	if storedSocketDir, err := readPersistentDaemonSocketDir(root); err == nil {
		paths.socket = filepath.Join(storedSocketDir, filepath.Base(paths.socket))
	} else if !errors.Is(err, os.ErrNotExist) {
		entry.Error = err.Error()
		return entry
	}
	entry.Socket = paths.socket

	token, err := readPersistentDaemonTokenFile(paths.tokenFile)
	if err != nil {
		if !errors.Is(err, os.ErrNotExist) {
			entry.Error = err.Error()
		}
		return entry
	}
	conn, err := dialPersistentDaemon(paths.socket, token)
	if err != nil {
		if !shouldRemovePersistentSocketAfterDialError(err) {
			entry.Error = err.Error()
		}
		return entry
	}
	defer conn.Close()
	populateDaemonStatusFromConn(conn, &entry)
	return entry
}

func populateDaemonStatusFromConn(conn net.Conn, entry *daemonStatusEntry) {
	reader := bufio.NewReaderSize(conn, 64*1024)
	resp, err := daemonStatusConnCall(conn, reader, rpcRequest{ID: "status", Method: "daemon.status"})
	if err != nil {
		entry.Error = err.Error()
		return
	}
	if resp.OK {
		entry.Running = true
		applyDaemonStatusResult(entry, resp.Result)
		return
	}
	if resp.Error == nil || resp.Error.Code != "method_not_found" {
		entry.Error = daemonStatusResponseError(resp)
		return
	}
	// Older daemons predate daemon.status; fall back to hello + pty.list.
	entry.Running = true
	helloResp, err := daemonStatusConnCall(conn, reader, rpcRequest{ID: "hello", Method: "hello"})
	if err != nil {
		entry.Error = err.Error()
		return
	}
	if helloResp.OK {
		if result, ok := helloResp.Result.(map[string]any); ok {
			if daemonVersion, hasVersion := getStringParam(result, "version"); hasVersion {
				entry.Version = daemonVersion
			}
		}
	}
	listResp, err := daemonStatusConnCall(conn, reader, rpcRequest{ID: "list", Method: "pty.list"})
	if err != nil {
		entry.Error = err.Error()
		return
	}
	if listResp.OK {
		if result, ok := listResp.Result.(map[string]any); ok {
			if sessions, hasSessions := result["sessions"].([]any); hasSessions {
				count := len(sessions)
				entry.PTYSessions = &count
			}
		}
	}
}

func applyDaemonStatusResult(entry *daemonStatusEntry, rawResult any) {
	result, ok := rawResult.(map[string]any)
	if !ok {
		return
	}
	if daemonVersion, hasVersion := getStringParam(result, "version"); hasVersion {
		entry.Version = daemonVersion
	}
	if pid, hasPID := getIntParam(result, "pid"); hasPID {
		entry.PID = pid
	}
	if startedAt, hasStartedAt := getIntParam(result, "started_at_unix"); hasStartedAt {
		entry.StartedAtUnix = int64(startedAt)
	}
	if uptime, hasUptime := getIntParam(result, "uptime_seconds"); hasUptime {
		uptimeSeconds := int64(uptime)
		entry.UptimeSeconds = &uptimeSeconds
	}
	if sessions, hasSessions := getIntParam(result, "pty_sessions"); hasSessions {
		count := sessions
		entry.PTYSessions = &count
	}
}

func daemonStatusResponseError(resp rpcResponse) string {
	if resp.Error == nil {
		return "daemon request failed"
	}
	message := strings.TrimSpace(resp.Error.Message)
	if message == "" {
		return strings.TrimSpace(resp.Error.Code)
	}
	return message
}

func daemonStatusConnCall(conn net.Conn, reader *bufio.Reader, req rpcRequest) (rpcResponse, error) {
	if err := conn.SetDeadline(time.Now().Add(daemonStatusProbeTimeout)); err != nil {
		return rpcResponse{}, err
	}
	defer conn.SetDeadline(time.Time{})
	data, err := json.Marshal(req)
	if err != nil {
		return rpcResponse{}, err
	}
	if _, err := conn.Write(append(data, '\n')); err != nil {
		return rpcResponse{}, err
	}
	line, oversized, err := readRPCFrame(reader, maxRPCFrameBytes)
	if err != nil {
		return rpcResponse{}, err
	}
	if oversized {
		return rpcResponse{}, errors.New("daemon response exceeded maximum size")
	}
	var resp rpcResponse
	if err := json.Unmarshal(bytes.TrimSpace(line), &resp); err != nil {
		return rpcResponse{}, err
	}
	return resp, nil
}

func writeDaemonStatusText(w io.Writer, output daemonStatusOutput) {
	_, _ = fmt.Fprintf(w, "slot: %s\n", output.Slot)
	_, _ = fmt.Fprintf(w, "root: %s\n", output.Root)
	_, _ = fmt.Fprintf(w, "binary_version: %s\n", output.BinaryVersion)
	if len(output.Daemons) == 0 {
		_, _ = fmt.Fprintln(w, "daemons: none")
		return
	}
	for _, daemon := range output.Daemons {
		state := "not running"
		if daemon.Running {
			state = "running"
		}
		_, _ = fmt.Fprintf(w, "daemon %s: %s\n", daemon.VersionDir, state)
		if daemon.Socket != "" {
			_, _ = fmt.Fprintf(w, "  socket: %s\n", daemon.Socket)
		}
		if daemon.Version != "" {
			_, _ = fmt.Fprintf(w, "  version: %s\n", daemon.Version)
		}
		if daemon.PID > 0 {
			_, _ = fmt.Fprintf(w, "  pid: %d\n", daemon.PID)
		}
		if daemon.StartedAtUnix > 0 {
			_, _ = fmt.Fprintf(w, "  started_at_unix: %d\n", daemon.StartedAtUnix)
		}
		if daemon.UptimeSeconds != nil {
			_, _ = fmt.Fprintf(w, "  uptime_seconds: %d\n", *daemon.UptimeSeconds)
		}
		if daemon.PTYSessions != nil {
			_, _ = fmt.Fprintf(w, "  pty_sessions: %d\n", *daemon.PTYSessions)
		}
		if daemon.Error != "" {
			_, _ = fmt.Fprintf(w, "  error: %s\n", daemon.Error)
		}
	}
}
