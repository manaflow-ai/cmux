package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"runtime"
	"sort"
	"strings"
	"syscall"
	"time"
)

type unixHeadlessServerConfig struct {
	SocketPath  string
	InstanceID  string
	Name        string
	RegistryDir string
	Shell       string
}

type headlessInstanceRecord struct {
	Version       int      `json:"version"`
	ID            string   `json:"id"`
	Name          string   `json:"name,omitempty"`
	Transport     string   `json:"transport"`
	SocketPath    string   `json:"socket_path"`
	PID           int      `json:"pid"`
	StartedAt     string   `json:"started_at"`
	GoOS          string   `json:"goos"`
	GoArch        string   `json:"goarch"`
	DaemonVersion string   `json:"daemon_version"`
	Capabilities  []string `json:"capabilities"`
}

type headlessInstanceStatus struct {
	headlessInstanceRecord
	Online      bool   `json:"online"`
	StaleReason string `json:"stale_reason,omitempty"`
}

func runUnixHeadlessServer(ctx context.Context, cfg unixHeadlessServerConfig, stderr io.Writer) error {
	instanceID, err := normalizeHeadlessInstanceID(cfg.InstanceID)
	if err != nil {
		return err
	}
	socketPath := strings.TrimSpace(cfg.SocketPath)
	if socketPath == "" {
		socketPath = defaultHeadlessSocketPath(instanceID)
	}
	absSocketPath, err := filepath.Abs(socketPath)
	if err != nil {
		return fmt.Errorf("resolve socket path: %w", err)
	}
	registryDir := strings.TrimSpace(cfg.RegistryDir)
	if registryDir == "" {
		registryDir = defaultHeadlessRegistryDir()
	}
	absRegistryDir, err := filepath.Abs(registryDir)
	if err != nil {
		return fmt.Errorf("resolve registry directory: %w", err)
	}

	if err := prepareUnixSocketPath(absSocketPath); err != nil {
		return err
	}
	listener, err := net.Listen("unix", absSocketPath)
	if err != nil {
		return err
	}
	// userRuntimeDir keeps the socket in a private 0700 directory, so tightening
	// it to 0600 here closes the remaining exposure with no meaningful TOCTOU
	// window (a process-wide umask would not be goroutine-safe). Remove the socket
	// on failure so a partially-initialized path is not left behind.
	if err := os.Chmod(absSocketPath, 0o600); err != nil {
		listener.Close()
		_ = os.Remove(absSocketPath)
		return fmt.Errorf("chmod headless socket %s: %w", absSocketPath, err)
	}
	defer listener.Close()
	defer os.Remove(absSocketPath)

	hub := newWebSocketPTYHub(wsPTYServerConfig{Shell: strings.TrimSpace(cfg.Shell)}, stderr)
	defer hub.closeAll()

	record := headlessInstanceRecord{
		Version:       1,
		ID:            instanceID,
		Name:          strings.TrimSpace(cfg.Name),
		Transport:     "unix",
		SocketPath:    absSocketPath,
		PID:           os.Getpid(),
		StartedAt:     time.Now().UTC().Format(time.RFC3339Nano),
		GoOS:          runtime.GOOS,
		GoArch:        runtime.GOARCH,
		DaemonVersion: version,
		Capabilities:  daemonCapabilities(),
	}
	if record.Name == "" {
		record.Name = instanceID
	}
	if err := registerHeadlessInstance(absRegistryDir, record); err != nil {
		return err
	}
	defer unregisterHeadlessInstance(absRegistryDir, instanceID)

	for {
		conn, err := listener.Accept()
		if err != nil {
			select {
			case <-ctx.Done():
				return ctx.Err()
			default:
				return err
			}
		}
		go func(conn net.Conn) {
			defer conn.Close()
			_ = serveRPCFrames(conn, conn, hub, false)
		}(conn)
	}
}

func runHeadless(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		headlessUsage(stderr)
		return 2
	}
	switch args[0] {
	case "list":
		return runHeadlessList(args[1:], stdout, stderr)
	case "connect":
		return runHeadlessConnect(args[1:], stdin, stdout, stderr)
	default:
		fmt.Fprintf(stderr, "cmuxd-remote headless: unknown subcommand %q\n", args[0])
		headlessUsage(stderr)
		return 2
	}
}

func headlessUsage(w io.Writer) {
	_, _ = fmt.Fprintln(w, "Usage:")
	_, _ = fmt.Fprintln(w, "  cmuxd-remote headless list [--json] [--registry-dir <dir>]")
	_, _ = fmt.Fprintln(w, "  cmuxd-remote headless connect (--id <id> | --socket <path>) [--registry-dir <dir>]")
}

func runHeadlessList(args []string, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("headless list", flag.ContinueOnError)
	fs.SetOutput(stderr)
	jsonOutput := fs.Bool("json", false, "print JSON")
	registryDir := fs.String("registry-dir", "", "headless instance registry directory")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if fs.NArg() != 0 {
		fmt.Fprintln(stderr, "headless list does not accept positional arguments")
		return 2
	}

	statuses, err := readHeadlessInstanceStatuses(strings.TrimSpace(*registryDir))
	if err != nil {
		fmt.Fprintf(stderr, "headless list: %v\n", err)
		return 1
	}
	if *jsonOutput {
		payload := map[string]any{"instances": statuses}
		data, err := json.MarshalIndent(payload, "", "  ")
		if err != nil {
			fmt.Fprintf(stderr, "headless list: encode JSON: %v\n", err)
			return 1
		}
		_, _ = fmt.Fprintln(stdout, string(data))
		return 0
	}
	if len(statuses) == 0 {
		_, _ = fmt.Fprintln(stdout, "No headless cmux instances")
		return 0
	}
	for _, status := range statuses {
		state := "online"
		if !status.Online {
			state = "offline"
		}
		name := status.Name
		if name == "" {
			name = status.ID
		}
		_, _ = fmt.Fprintf(stdout, "%s\t%s\t%s\t%s\n", status.ID, state, name, status.SocketPath)
	}
	return 0
}

func runHeadlessConnect(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	fs := flag.NewFlagSet("headless connect", flag.ContinueOnError)
	fs.SetOutput(stderr)
	instanceID := fs.String("id", "default", "headless instance id")
	socketPath := fs.String("socket", "", "headless instance Unix socket path")
	registryDir := fs.String("registry-dir", "", "headless instance registry directory")
	if err := fs.Parse(args); err != nil {
		return 2
	}
	if fs.NArg() != 0 {
		fmt.Fprintln(stderr, "headless connect does not accept positional arguments")
		return 2
	}

	targetSocket := strings.TrimSpace(*socketPath)
	if targetSocket == "" {
		record, err := findHeadlessInstance(strings.TrimSpace(*registryDir), strings.TrimSpace(*instanceID))
		if err != nil {
			fmt.Fprintf(stderr, "headless connect: %v\n", err)
			return 1
		}
		targetSocket = record.SocketPath
	}
	conn, err := net.Dial("unix", targetSocket)
	if err != nil {
		fmt.Fprintf(stderr, "headless connect: %v\n", err)
		return 1
	}
	defer conn.Close()

	if err := proxyHeadlessConnection(conn, stdin, stdout); err != nil {
		fmt.Fprintf(stderr, "headless connect: %v\n", err)
		return 1
	}
	return 0
}

func proxyHeadlessConnection(conn net.Conn, stdin io.Reader, stdout io.Writer) error {
	type copyResult struct {
		direction string
		err       error
	}
	errs := make(chan copyResult, 2)
	go func() {
		_, err := io.Copy(conn, stdin)
		if closeWriter, ok := conn.(interface{ CloseWrite() error }); ok {
			_ = closeWriter.CloseWrite()
		} else {
			_ = conn.Close()
		}
		errs <- copyResult{direction: "stdin", err: err}
	}()
	go func() {
		_, err := io.Copy(stdout, conn)
		errs <- copyResult{direction: "stdout", err: err}
	}()

	var firstErr error
	for i := 0; i < 2; i++ {
		result := <-errs
		if result.err != nil && !errors.Is(result.err, net.ErrClosed) && firstErr == nil {
			firstErr = result.err
		}
		if result.direction == "stdout" {
			return firstErr
		}
	}
	return firstErr
}

func findHeadlessInstance(registryDir string, rawID string) (headlessInstanceStatus, error) {
	instanceID, err := normalizeHeadlessInstanceID(rawID)
	if err != nil {
		return headlessInstanceStatus{}, err
	}
	statuses, err := readHeadlessInstanceStatuses(registryDir)
	if err != nil {
		return headlessInstanceStatus{}, err
	}
	for _, status := range statuses {
		if status.ID == instanceID {
			if !status.Online {
				return headlessInstanceStatus{}, fmt.Errorf("instance %q is offline: %s", instanceID, status.StaleReason)
			}
			return status, nil
		}
	}
	return headlessInstanceStatus{}, fmt.Errorf("instance %q not found", instanceID)
}

func readHeadlessInstanceStatuses(registryDir string) ([]headlessInstanceStatus, error) {
	dir := strings.TrimSpace(registryDir)
	if dir == "" {
		dir = defaultHeadlessRegistryDir()
	}
	entries, err := os.ReadDir(dir)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil, nil
		}
		return nil, err
	}
	statuses := make([]headlessInstanceStatus, 0, len(entries))
	for _, entry := range entries {
		if entry.IsDir() || filepath.Ext(entry.Name()) != ".json" {
			continue
		}
		data, err := os.ReadFile(filepath.Join(dir, entry.Name()))
		if err != nil {
			continue
		}
		var record headlessInstanceRecord
		if err := json.Unmarshal(data, &record); err != nil {
			continue
		}
		if _, err := normalizeHeadlessInstanceID(record.ID); err != nil {
			continue
		}
		statuses = append(statuses, statusHeadlessInstance(record))
	}
	sort.Slice(statuses, func(i, j int) bool {
		if statuses[i].Online != statuses[j].Online {
			return statuses[i].Online
		}
		return statuses[i].ID < statuses[j].ID
	})
	return statuses, nil
}

func statusHeadlessInstance(record headlessInstanceRecord) headlessInstanceStatus {
	status := headlessInstanceStatus{headlessInstanceRecord: record}
	if strings.TrimSpace(record.SocketPath) == "" {
		status.StaleReason = "missing socket path"
		return status
	}
	info, err := os.Lstat(record.SocketPath)
	if err != nil {
		status.StaleReason = "socket missing"
		return status
	}
	if info.Mode()&os.ModeSocket == 0 {
		status.StaleReason = "socket path is not a Unix socket"
		return status
	}
	if record.PID > 0 && !processExists(record.PID) {
		status.StaleReason = "process is not running"
		return status
	}
	status.Online = true
	return status
}

func registerHeadlessInstance(registryDir string, record headlessInstanceRecord) error {
	if err := os.MkdirAll(registryDir, 0o700); err != nil {
		return err
	}
	data, err := json.MarshalIndent(record, "", "  ")
	if err != nil {
		return err
	}
	path := headlessRegistryPath(registryDir, record.ID)
	tmp := path + ".tmp"
	if err := os.WriteFile(tmp, append(data, '\n'), 0o600); err != nil {
		return err
	}
	return os.Rename(tmp, path)
}

func unregisterHeadlessInstance(registryDir string, instanceID string) {
	id, err := normalizeHeadlessInstanceID(instanceID)
	if err != nil {
		return
	}
	_ = os.Remove(headlessRegistryPath(registryDir, id))
}

func headlessRegistryPath(registryDir string, instanceID string) string {
	return filepath.Join(registryDir, instanceID+".json")
}

func prepareUnixSocketPath(socketPath string) error {
	if err := os.MkdirAll(filepath.Dir(socketPath), 0o700); err != nil {
		return err
	}
	info, err := os.Lstat(socketPath)
	if err != nil {
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		return err
	}
	if info.Mode()&os.ModeSocket == 0 {
		return fmt.Errorf("socket path exists and is not a Unix socket: %s", socketPath)
	}
	conn, dialErr := net.DialTimeout("unix", socketPath, 150*time.Millisecond)
	if dialErr == nil {
		_ = conn.Close()
		return fmt.Errorf("socket already accepts connections: %s", socketPath)
	}
	return os.Remove(socketPath)
}

func normalizeHeadlessInstanceID(raw string) (string, error) {
	id := strings.TrimSpace(raw)
	if id == "" {
		id = "default"
	}
	if len(id) > 64 {
		return "", fmt.Errorf("headless instance id is too long")
	}
	for _, r := range id {
		if (r >= 'a' && r <= 'z') ||
			(r >= 'A' && r <= 'Z') ||
			(r >= '0' && r <= '9') ||
			r == '-' || r == '_' || r == '.' {
			continue
		}
		return "", fmt.Errorf("headless instance id %q contains unsupported characters", id)
	}
	return id, nil
}

func defaultHeadlessRegistryDir() string {
	home, err := os.UserHomeDir()
	if err != nil || strings.TrimSpace(home) == "" {
		return filepath.Join(os.TempDir(), fmt.Sprintf("cmux-headless-%d", os.Getuid()), "instances")
	}
	return filepath.Join(home, ".cmux", "headless", "instances")
}

func defaultHeadlessSocketPath(instanceID string) string {
	socketName := fmt.Sprintf("cmux-headless-%d-%s.sock", os.Getuid(), instanceID)
	if dir := userRuntimeDir(); dir != "" {
		return filepath.Join(dir, socketName)
	}
	return filepath.Join("/tmp", socketName)
}

// userRuntimeDir returns a private per-user runtime directory for the headless
// instance socket, preferring $XDG_RUNTIME_DIR and falling back to /run/user/<uid>
// when it exists. It only accepts a directory that is owned by the current user
// and not accessible by group/other, so an attacker-controlled $XDG_RUNTIME_DIR
// cannot redirect the socket into a shared location; otherwise it returns "" and
// the caller falls back to the world-traversable temp dir.
func userRuntimeDir() string {
	if dir := strings.TrimSpace(os.Getenv("XDG_RUNTIME_DIR")); dir != "" && isPrivateDir(dir) {
		return dir
	}
	if runUser := fmt.Sprintf("/run/user/%d", os.Getuid()); isPrivateDir(runUser) {
		return runUser
	}
	return ""
}

// isPrivateDir reports whether path is a directory owned by the current user with
// no group/other access (mode 0700), so a socket placed there stays private.
func isPrivateDir(path string) bool {
	info, err := os.Stat(path)
	if err != nil || !info.IsDir() || info.Mode().Perm()&0o077 != 0 {
		return false
	}
	st, ok := info.Sys().(*syscall.Stat_t)
	return ok && int(st.Uid) == os.Getuid()
}

func processExists(pid int) bool {
	if pid <= 0 {
		return false
	}
	err := syscall.Kill(pid, 0)
	return err == nil || errors.Is(err, syscall.EPERM)
}
