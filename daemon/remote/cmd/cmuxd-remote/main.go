package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/rand"
	"crypto/sha256"
	"crypto/subtle"
	"encoding/base64"
	"encoding/hex"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"math"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"syscall"
	"time"
)

var version = "dev"

type rpcRequest struct {
	ID     any            `json:"id"`
	HasID  bool           `json:"-"`
	Method string         `json:"method"`
	Params map[string]any `json:"params"`
}

func (r *rpcRequest) UnmarshalJSON(data []byte) error {
	type rpcRequestWire struct {
		ID     json.RawMessage `json:"id"`
		Method string          `json:"method"`
		Params map[string]any  `json:"params"`
	}
	var wire rpcRequestWire
	if err := json.Unmarshal(data, &wire); err != nil {
		return err
	}
	r.HasID = len(wire.ID) > 0
	r.ID = nil
	if r.HasID && string(wire.ID) != "null" {
		if err := json.Unmarshal(wire.ID, &r.ID); err != nil {
			return err
		}
	}
	r.Method = wire.Method
	r.Params = wire.Params
	return nil
}

type rpcError struct {
	Code    string `json:"code"`
	Message string `json:"message"`
}

type rpcResponse struct {
	ID     any       `json:"id,omitempty"`
	OK     bool      `json:"ok"`
	Result any       `json:"result,omitempty"`
	Error  *rpcError `json:"error,omitempty"`
}

type rpcEvent struct {
	Event           string `json:"event"`
	StreamID        string `json:"stream_id,omitempty"`
	RequestID       string `json:"request_id,omitempty"`
	SessionID       string `json:"session_id,omitempty"`
	AttachmentID    string `json:"attachment_id,omitempty"`
	AttachmentToken string `json:"attachment_token,omitempty"`
	DataBase64      string `json:"data_base64,omitempty"`
	Message         string `json:"message,omitempty"`
	Error           string `json:"error,omitempty"`
	Seq             uint64 `json:"seq,omitempty"`
}

type rpcFrameWriter interface {
	writeResponse(rpcResponse) error
	writeEvent(rpcEvent) error
}

type streamState struct {
	conn          net.Conn
	readerStarted bool
}

type stdioFrameWriter struct {
	mu     sync.Mutex
	writer *bufio.Writer
}

type rpcServer struct {
	mu             sync.Mutex
	nextStreamID   uint64
	nextSessionID  uint64
	streams        map[string]*streamState
	sessions       map[string]*sessionState
	ptyHub         *wsPTYHub
	ownsPTYHub     bool
	ptyAttachments map[string]*wsPTYAttachment
	frameWriter    rpcFrameWriter
	cliBridge      *cloudCLIBridge
}

type sessionAttachment struct {
	Cols      int
	Rows      int
	UpdatedAt time.Time
}

type sessionState struct {
	attachments   map[string]sessionAttachment
	effectiveCols int
	effectiveRows int
	lastKnownCols int
	lastKnownRows int
}

const maxRPCFrameBytes = 4 * 1024 * 1024

func main() {
	if shouldRunCLIForInvocation(os.Args[0], os.Args[1:]) {
		os.Exit(runCLI(os.Args[1:]))
	}
	os.Exit(run(os.Args[1:], os.Stdin, os.Stdout, os.Stderr))
}

func shouldRunCLIForInvocation(argv0 string, args []string) bool {
	base := filepath.Base(argv0)
	if base == "cmux" {
		return true
	}
	if !strings.HasPrefix(base, "cmuxd-remote") || len(args) == 0 {
		return false
	}
	return !isDaemonEntryCommand(args[0])
}

func isDaemonEntryCommand(arg string) bool {
	switch arg {
	case "version", "serve", "cli":
		return true
	default:
		return false
	}
}

func run(args []string, stdin io.Reader, stdout, stderr io.Writer) int {
	if len(args) == 0 {
		usage(stderr)
		return 2
	}

	switch args[0] {
	case "version":
		_, _ = fmt.Fprintln(stdout, version)
		return 0
	case "serve":
		fs := flag.NewFlagSet("serve", flag.ContinueOnError)
		fs.SetOutput(stderr)
		stdio := fs.Bool("stdio", false, "serve over stdin/stdout")
		ws := fs.Bool("ws", false, "serve terminal PTY transport over WebSocket")
		persistent := fs.Bool("persistent", false, "proxy stdio to a persistent per-slot daemon")
		persistentServer := fs.Bool("persistent-server", false, "run the persistent per-slot daemon")
		persistentSlot := fs.String("slot", "", "persistent daemon slot")
		listen := fs.String("listen", "127.0.0.1:7777", "address for --ws")
		authLeaseFile := fs.String("auth-lease-file", "", "required lease JSON path for --ws")
		rpcAuthLeaseFile := fs.String("rpc-auth-lease-file", "", "optional daemon RPC lease JSON path for --ws /rpc")
		adminTokenSHA256 := fs.String("admin-token-sha256", "", "optional bearer token SHA-256 for HTTPS lease installation")
		adminEd25519PublicKey := fs.String("admin-ed25519-public-key", "", "optional base64 Ed25519 public key for signed HTTPS lease installation")
		shell := fs.String("shell", "", "shell path for --ws PTY sessions")
		if err := fs.Parse(args[1:]); err != nil {
			return 2
		}
		if *persistentServer {
			if *stdio || *ws || *persistent {
				_, _ = fmt.Fprintln(stderr, "serve --persistent-server cannot be combined with --stdio, --ws, or --persistent")
				return 2
			}
			if strings.TrimSpace(*persistentSlot) == "" {
				_, _ = fmt.Fprintln(stderr, "serve --persistent-server requires --slot")
				return 2
			}
			if err := runPersistentDaemonServer(strings.TrimSpace(*persistentSlot), stderr); err != nil {
				_, _ = fmt.Fprintf(stderr, "serve --persistent-server failed: %v\n", err)
				return 1
			}
			return 0
		}
		if *stdio == *ws {
			_, _ = fmt.Fprintln(stderr, "serve requires exactly one of --stdio or --ws")
			return 2
		}
		if (*persistent || strings.TrimSpace(*persistentSlot) != "") && !*stdio {
			_, _ = fmt.Fprintln(stderr, "serve --persistent requires --stdio")
			return 2
		}
		if strings.TrimSpace(*persistentSlot) != "" && !*persistent {
			_, _ = fmt.Fprintln(stderr, "serve --slot requires --persistent")
			return 2
		}
		if *ws {
			if strings.TrimSpace(*authLeaseFile) == "" {
				_, _ = fmt.Fprintln(stderr, "serve --ws requires --auth-lease-file")
				return 2
			}
			if err := runWebSocketPTYServer(context.Background(), wsPTYServerConfig{
				ListenAddr:       strings.TrimSpace(*listen),
				PTYAuthLeaseFile: strings.TrimSpace(*authLeaseFile),
				RPCAuthLeaseFile: strings.TrimSpace(*rpcAuthLeaseFile),
				AdminTokenSHA256: firstNonEmpty(strings.TrimSpace(*adminTokenSHA256), strings.TrimSpace(os.Getenv("CMUXD_WS_ADMIN_TOKEN_SHA256"))),
				AdminEd25519PubKey: firstNonEmpty(
					strings.TrimSpace(*adminEd25519PublicKey),
					strings.TrimSpace(os.Getenv("CMUXD_WS_ADMIN_ED25519_PUBLIC_KEY")),
				),
				Shell: strings.TrimSpace(*shell),
			}, stderr); err != nil {
				_, _ = fmt.Fprintf(stderr, "serve --ws failed: %v\n", err)
				return 1
			}
			return 0
		}
		if *persistent {
			if strings.TrimSpace(*persistentSlot) == "" {
				_, _ = fmt.Fprintln(stderr, "serve --persistent requires --slot")
				return 2
			}
			if err := runPersistentStdioProxy(stdin, stdout, stderr, strings.TrimSpace(*persistentSlot)); err != nil {
				_, _ = fmt.Fprintf(stderr, "serve --stdio --persistent failed: %v\n", err)
				return 1
			}
			return 0
		}
		if err := runStdioServer(stdin, stdout); err != nil {
			_, _ = fmt.Fprintf(stderr, "serve failed: %v\n", err)
			return 1
		}
		return 0
	case "cli":
		return runCLI(args[1:])
	default:
		usage(stderr)
		return 2
	}
}

func usage(w io.Writer) {
	_, _ = fmt.Fprintln(w, "Usage:")
	_, _ = fmt.Fprintln(w, "  cmuxd-remote version")
	_, _ = fmt.Fprintln(w, "  cmuxd-remote serve --stdio")
	_, _ = fmt.Fprintln(w, "  cmuxd-remote serve --stdio --persistent --slot <slot>")
	_, _ = fmt.Fprintln(w, "  cmuxd-remote serve --ws --auth-lease-file <path> [--rpc-auth-lease-file <path>] [--listen 127.0.0.1:7777]")
	_, _ = fmt.Fprintln(w, "  cmuxd-remote cli <command> [args...]")
}

func runStdioServer(stdin io.Reader, stdout io.Writer) error {
	return runRPCServer(stdin, stdout, newWebSocketPTYHub(wsPTYServerConfig{}, io.Discard), true)
}

func runRPCServer(stdin io.Reader, stdout io.Writer, ptyHub *wsPTYHub, ownsPTYHub bool) error {
	writer := &stdioFrameWriter{
		writer: bufio.NewWriter(stdout),
	}
	server := &rpcServer{
		nextStreamID:  1,
		nextSessionID: 1,
		streams:       map[string]*streamState{},
		sessions:      map[string]*sessionState{},
		ptyHub:        ptyHub,
		ownsPTYHub:    ownsPTYHub,
		frameWriter:   writer,
	}
	defer server.closeAll()

	reader := bufio.NewReaderSize(stdin, 64*1024)
	defer writer.writer.Flush()

	for {
		line, oversized, readErr := readRPCFrame(reader, maxRPCFrameBytes)
		if readErr != nil {
			if errors.Is(readErr, io.EOF) {
				return nil
			}
			return readErr
		}
		if oversized {
			if err := writer.writeResponse(rpcResponse{
				OK: false,
				Error: &rpcError{
					Code:    "invalid_request",
					Message: "request frame exceeds maximum size",
				},
			}); err != nil {
				return err
			}
			continue
		}
		line = bytes.TrimSuffix(line, []byte{'\n'})
		line = bytes.TrimSuffix(line, []byte{'\r'})
		if len(line) == 0 {
			continue
		}

		var req rpcRequest
		if err := json.Unmarshal(line, &req); err != nil {
			if err := writer.writeResponse(rpcResponse{
				OK: false,
				Error: &rpcError{
					Code:    "invalid_request",
					Message: "invalid JSON request",
				},
			}); err != nil {
				return err
			}
			continue
		}

		if err := server.handleRequestAndWriteResponse(req); err != nil {
			return err
		}
	}
}

type persistentDaemonPaths struct {
	slot      string
	root      string
	socket    string
	tokenFile string
	logFile   string
	lockFile  string
}

const (
	persistentDaemonAuthMethod    = "daemon.auth"
	persistentDaemonReadyFDEnv    = "CMUX_REMOTE_DAEMON_READY_FD"
	persistentDaemonAuthTimeout   = 5 * time.Second
	persistentDaemonSocketDirFile = "socket-dir"
)

var errPersistentDaemonAuthFailed = errors.New("persistent daemon authentication failed")

const (
	persistentDaemonStartupTimeout    = 5 * time.Second
	persistentDaemonEmptyIdleTimeout  = 5 * time.Minute
	persistentDaemonEmptyIdlePollStep = time.Second
)

type persistentDaemonServerConfig struct {
	emptyIdleTimeout time.Duration
	acceptPollStep   time.Duration
}

func persistentDaemonPathsForSlot(rawSlot string) (persistentDaemonPaths, error) {
	slot, err := validatePersistentDaemonSlot(rawSlot)
	if err != nil {
		return persistentDaemonPaths{}, err
	}
	rootBase := strings.TrimSpace(os.Getenv("CMUX_REMOTE_DAEMON_ROOT"))
	if rootBase == "" {
		home, homeErr := os.UserHomeDir()
		if homeErr != nil || strings.TrimSpace(home) == "" {
			return persistentDaemonPaths{}, errors.New("cannot resolve remote home directory")
		}
		rootBase = filepath.Join(home, ".cmux", "daemon")
	}
	root := filepath.Join(rootBase, persistentDaemonVersionComponent(), slot)
	socketPath := persistentDaemonSocketPath(root, slot)
	return persistentDaemonPaths{
		slot:      slot,
		root:      root,
		socket:    socketPath,
		tokenFile: filepath.Join(root, "auth.token"),
		logFile:   filepath.Join(root, "daemon.log"),
		lockFile:  filepath.Join(root, "daemon.lock"),
	}, nil
}

func persistentDaemonVersionComponent() string {
	trimmed := strings.TrimSpace(version)
	if trimmed == "" {
		trimmed = "dev"
	}
	var builder strings.Builder
	for _, r := range trimmed {
		if (r >= 'a' && r <= 'z') ||
			(r >= 'A' && r <= 'Z') ||
			(r >= '0' && r <= '9') ||
			r == '-' ||
			r == '_' ||
			r == '.' {
			builder.WriteRune(r)
		} else {
			builder.WriteByte('_')
		}
	}
	component := builder.String()
	if component == "" || component == "." || component == ".." {
		return "dev"
	}
	if len(component) <= 64 {
		return component
	}
	digest := sha256.Sum256([]byte(trimmed))
	return component[:48] + "-" + hex.EncodeToString(digest[:4])
}

func persistentDaemonSocketPath(root string, slot string) string {
	socketBase, overrideSet := persistentDaemonSocketBase()
	if !overrideSet {
		socketBase = filepath.Join("/tmp", fmt.Sprintf("cmuxd-remote-%d", os.Getuid()))
	}
	digest := sha256.Sum256([]byte(root + "\x00" + slot))
	return filepath.Join(socketBase, "cmuxd-"+hex.EncodeToString(digest[:8])+".sock")
}

func persistentDaemonSocketBase() (string, bool) {
	socketBase := strings.TrimSpace(os.Getenv("CMUX_REMOTE_DAEMON_SOCKET_DIR"))
	if socketBase == "" {
		return "", false
	}
	return filepath.Join(socketBase, fmt.Sprintf("cmuxd-remote-%d", os.Getuid())), true
}

func validatePersistentDaemonSlot(rawSlot string) (string, error) {
	slot := strings.TrimSpace(rawSlot)
	if slot == "" {
		return "", errors.New("persistent daemon slot is required")
	}
	if slot == "." || slot == ".." || len(slot) > 128 {
		return "", fmt.Errorf("invalid persistent daemon slot %q", rawSlot)
	}
	for _, r := range slot {
		if (r >= 'a' && r <= 'z') ||
			(r >= 'A' && r <= 'Z') ||
			(r >= '0' && r <= '9') ||
			r == '-' ||
			r == '_' ||
			r == '.' {
			continue
		}
		return "", fmt.Errorf("invalid persistent daemon slot %q", rawSlot)
	}
	return slot, nil
}

func ensurePersistentDaemonDirectory(paths persistentDaemonPaths) (persistentDaemonPaths, error) {
	if err := os.MkdirAll(paths.root, 0o700); err != nil {
		return paths, err
	}
	if err := verifyPrivateDaemonDirectory(paths.root); err != nil {
		return paths, err
	}
	socketDir := filepath.Dir(paths.socket)
	secureSocketDir, err := ensurePersistentDaemonSocketDirectory(paths.root, socketDir)
	if err != nil {
		return paths, err
	}
	paths.socket = filepath.Join(secureSocketDir, filepath.Base(paths.socket))
	return paths, nil
}

func ensurePersistentDaemonSocketDirectory(root string, defaultSocketDir string) (string, error) {
	if storedSocketDir, err := readPersistentDaemonSocketDir(root); err == nil {
		if verifyErr := ensurePrivateDaemonLeafDirectory(storedSocketDir); verifyErr == nil {
			return storedSocketDir, nil
		}
		if removeErr := removePersistentDaemonSocketDirMetadata(root); removeErr != nil {
			return "", removeErr
		}
	} else if !errors.Is(err, os.ErrNotExist) {
		return "", err
	}

	if err := ensurePrivateDaemonLeafDirectory(defaultSocketDir); err == nil {
		return defaultSocketDir, nil
	}
	return createPersistentDaemonFallbackSocketDir(root)
}

func ensurePrivateDaemonLeafDirectory(path string) error {
	if err := os.MkdirAll(filepath.Dir(path), 0o755); err != nil {
		return err
	}
	if err := os.Mkdir(path, 0o700); err != nil && !errors.Is(err, os.ErrExist) {
		return err
	}
	return verifyPrivateDaemonDirectory(path)
}

func verifyPrivateDaemonDirectory(path string) error {
	info, err := os.Lstat(path)
	if err != nil {
		return err
	}
	if info.Mode()&os.ModeSymlink != 0 {
		return fmt.Errorf("persistent daemon directory %q is a symlink", path)
	}
	if !info.IsDir() {
		return fmt.Errorf("persistent daemon directory %q is not a directory", path)
	}
	if !daemonDirectoryOwnedByCurrentUser(info) {
		return fmt.Errorf("persistent daemon directory %q is not owned by uid %d", path, os.Getuid())
	}
	if info.Mode().Perm() != 0o700 {
		if err := os.Chmod(path, 0o700); err != nil {
			return err
		}
		info, err = os.Lstat(path)
		if err != nil {
			return err
		}
		if info.Mode()&os.ModeSymlink != 0 ||
			!info.IsDir() ||
			!daemonDirectoryOwnedByCurrentUser(info) ||
			info.Mode().Perm() != 0o700 {
			return fmt.Errorf("persistent daemon directory %q is not private", path)
		}
	}
	return nil
}

func daemonDirectoryOwnedByCurrentUser(info os.FileInfo) bool {
	stat, ok := info.Sys().(*syscall.Stat_t)
	return !ok || int(stat.Uid) == os.Getuid()
}

func readPersistentDaemonSocketDir(root string) (string, error) {
	data, err := os.ReadFile(filepath.Join(root, persistentDaemonSocketDirFile))
	if err != nil {
		return "", err
	}
	socketDir := strings.TrimSpace(string(data))
	if socketDir == "" {
		return "", errors.New("persistent daemon socket directory file is empty")
	}
	return socketDir, nil
}

func createPersistentDaemonFallbackSocketDir(root string) (string, error) {
	for attempt := 0; attempt < 8; attempt++ {
		raw := make([]byte, 8)
		if _, err := rand.Read(raw); err != nil {
			return "", err
		}
		socketDir := filepath.Join(
			os.TempDir(),
			fmt.Sprintf("cmuxd-remote-%d-%s", os.Getuid(), hex.EncodeToString(raw)),
		)
		if err := os.Mkdir(socketDir, 0o700); err != nil {
			if errors.Is(err, os.ErrExist) {
				continue
			}
			return "", err
		}
		if err := writePersistentDaemonSocketDir(root, socketDir); err != nil {
			_ = os.Remove(socketDir)
			if errors.Is(err, os.ErrExist) {
				if storedSocketDir, readErr := readPersistentDaemonSocketDir(root); readErr == nil {
					if verifyErr := ensurePrivateDaemonLeafDirectory(storedSocketDir); verifyErr == nil {
						return storedSocketDir, nil
					}
				}
				if removeErr := removePersistentDaemonSocketDirMetadata(root); removeErr != nil {
					return "", removeErr
				}
				continue
			}
			return "", err
		}
		return socketDir, nil
	}
	return "", errors.New("failed to create private persistent daemon socket directory")
}

func writePersistentDaemonSocketDir(root string, socketDir string) error {
	file, err := os.CreateTemp(root, ".socket-dir.*.tmp")
	if err != nil {
		return err
	}
	tmpPath := file.Name()
	closeOK := false
	defer func() {
		if !closeOK {
			_ = file.Close()
		}
		_ = os.Remove(tmpPath)
	}()
	if err := file.Chmod(0o600); err != nil {
		return err
	}
	if _, err := file.WriteString(socketDir + "\n"); err != nil {
		return err
	}
	if err := file.Close(); err != nil {
		return err
	}
	closeOK = true
	return os.Link(tmpPath, filepath.Join(root, persistentDaemonSocketDirFile))
}

func removePersistentDaemonSocketDirMetadata(root string) error {
	if err := os.Remove(filepath.Join(root, persistentDaemonSocketDirFile)); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}
	return nil
}

func persistentDaemonToken(paths persistentDaemonPaths) (string, error) {
	if token, err := readPersistentDaemonTokenFile(paths.tokenFile); err == nil {
		return token, nil
	} else if !errors.Is(err, os.ErrNotExist) {
		return "", err
	}

	raw := make([]byte, 32)
	if _, err := rand.Read(raw); err != nil {
		return "", err
	}
	token := hex.EncodeToString(raw)

	file, err := os.CreateTemp(filepath.Dir(paths.tokenFile), ".auth.token.*.tmp")
	if err != nil {
		return "", err
	}
	tmpPath := file.Name()
	closeOK := false
	defer func() {
		if !closeOK {
			_ = file.Close()
		}
		_ = os.Remove(tmpPath)
	}()
	if _, err := file.WriteString(token + "\n"); err != nil {
		return "", err
	}
	if err := file.Close(); err != nil {
		return "", err
	}
	closeOK = true
	if err := os.Link(tmpPath, paths.tokenFile); err != nil {
		if errors.Is(err, os.ErrExist) {
			return readPersistentDaemonTokenFile(paths.tokenFile)
		}
		return "", err
	}
	return token, nil
}

func readPersistentDaemonTokenFile(tokenFile string) (string, error) {
	data, err := os.ReadFile(tokenFile)
	if err != nil {
		return "", err
	}
	token := strings.TrimSpace(string(data))
	if token == "" {
		return "", errors.New("persistent daemon token file is empty")
	}
	return token, nil
}

func runPersistentStdioProxy(stdin io.Reader, stdout, stderr io.Writer, slot string) error {
	paths, err := persistentDaemonPathsForSlot(slot)
	if err != nil {
		return err
	}
	paths, err = ensurePersistentDaemonDirectory(paths)
	if err != nil {
		return err
	}
	token, err := persistentDaemonToken(paths)
	if err != nil {
		return err
	}
	if err := ensurePersistentDaemonRunning(paths, token, stderr); err != nil {
		return err
	}
	conn, err := dialPersistentDaemon(paths.socket, token)
	if err != nil {
		return err
	}
	return proxyPersistentDaemonConn(stdin, stdout, conn)
}

type persistentProxyCopyResult struct {
	stream string
	err    error
}

func proxyPersistentDaemonConn(stdin io.Reader, stdout io.Writer, conn net.Conn) error {
	defer conn.Close()
	errCh := make(chan persistentProxyCopyResult, 2)
	go func() {
		_, copyErr := io.Copy(conn, stdin)
		if unixConn, ok := conn.(*net.UnixConn); ok {
			_ = unixConn.CloseWrite()
		}
		errCh <- persistentProxyCopyResult{stream: "stdin", err: copyErr}
	}()
	go func() {
		_, copyErr := io.Copy(stdout, conn)
		errCh <- persistentProxyCopyResult{stream: "stdout", err: copyErr}
	}()

	first := <-errCh
	if first.stream == "stdout" {
		return persistentProxyCopyError(first.err)
	}
	second := <-errCh
	if firstErr := persistentProxyCopyError(first.err); firstErr != nil {
		return firstErr
	}
	return persistentProxyCopyError(second.err)
}

func persistentProxyCopyError(err error) error {
	if err == nil ||
		errors.Is(err, net.ErrClosed) ||
		errors.Is(err, os.ErrClosed) ||
		errors.Is(err, io.ErrClosedPipe) ||
		errors.Is(err, syscall.EPIPE) {
		return nil
	}
	return err
}

func ensurePersistentDaemonRunning(paths persistentDaemonPaths, token string, stderr io.Writer) error {
	if conn, err := dialPersistentDaemon(paths.socket, token); err == nil {
		_ = conn.Close()
		return nil
	} else if shouldRemovePersistentSocketAfterDialError(err) {
		_ = os.Remove(paths.socket)
	} else {
		return err
	}

	executable, err := os.Executable()
	if err != nil {
		return err
	}
	logFile, err := os.OpenFile(paths.logFile, os.O_CREATE|os.O_WRONLY|os.O_APPEND, 0o600)
	if err != nil {
		return err
	}
	defer logFile.Close()

	readyReader, readyWriter, err := os.Pipe()
	if err != nil {
		return err
	}
	defer readyReader.Close()
	defer readyWriter.Close()

	cmd := exec.Command(executable, "serve", "--persistent-server", "--slot", paths.slot)
	cmd.Stdin = nil
	cmd.Stdout = logFile
	cmd.Stderr = logFile
	cmd.Env = append(os.Environ(), persistentDaemonReadyFDEnv+"=3")
	cmd.ExtraFiles = []*os.File{readyWriter}
	cmd.SysProcAttr = &syscall.SysProcAttr{Setsid: true}
	if err := cmd.Start(); err != nil {
		return err
	}
	_ = readyWriter.Close()
	_ = cmd.Process.Release()

	if err := waitPersistentDaemonReady(readyReader, paths.logFile); err != nil {
		if conn, dialErr := dialPersistentDaemon(paths.socket, token); dialErr == nil {
			_ = conn.Close()
			return nil
		}
		if stderr != nil {
			_, _ = fmt.Fprintf(stderr, "persistent daemon log: %s\n", paths.logFile)
		}
		return err
	}

	conn, err := dialPersistentDaemon(paths.socket, token)
	if err == nil {
		_ = conn.Close()
		return nil
	}
	if stderr != nil {
		_, _ = fmt.Fprintf(stderr, "persistent daemon log: %s\n", paths.logFile)
	}
	return err
}

func shouldRemovePersistentSocketAfterDialError(err error) bool {
	return errors.Is(err, os.ErrNotExist) ||
		errors.Is(err, syscall.ENOENT) ||
		errors.Is(err, syscall.ECONNREFUSED)
}

func waitPersistentDaemonReady(reader *os.File, logFile string) error {
	done := make(chan error, 1)
	go func() {
		line, err := bufio.NewReader(reader).ReadString('\n')
		if err != nil {
			done <- fmt.Errorf("persistent daemon exited before readiness signal; log: %s: %w", logFile, err)
			return
		}
		if strings.TrimSpace(line) != "ready" {
			done <- fmt.Errorf("persistent daemon sent unexpected readiness signal %q; log: %s", strings.TrimSpace(line), logFile)
			return
		}
		done <- nil
	}()

	timer := time.NewTimer(5 * time.Second)
	defer timer.Stop()
	select {
	case err := <-done:
		return err
	case <-timer.C:
		return fmt.Errorf("persistent daemon did not become ready; log: %s", logFile)
	}
}

func runPersistentDaemonServer(slot string, stderr io.Writer) error {
	paths, err := persistentDaemonPathsForSlot(slot)
	if err != nil {
		return err
	}
	paths, err = ensurePersistentDaemonDirectory(paths)
	if err != nil {
		return err
	}
	token, err := persistentDaemonToken(paths)
	if err != nil {
		return err
	}
	lockFile, err := os.OpenFile(paths.lockFile, os.O_CREATE|os.O_RDWR, 0o600)
	if err != nil {
		return err
	}
	defer lockFile.Close()
	if err := syscall.Flock(int(lockFile.Fd()), syscall.LOCK_EX|syscall.LOCK_NB); err != nil {
		return fmt.Errorf("persistent daemon slot %q is already running", paths.slot)
	}
	defer syscall.Flock(int(lockFile.Fd()), syscall.LOCK_UN)

	_ = os.Remove(paths.socket)
	listener, err := net.Listen("unix", paths.socket)
	if err != nil {
		return err
	}
	defer listener.Close()
	defer os.Remove(paths.socket)
	_ = os.Chmod(paths.socket, 0o600)

	signalPersistentDaemonReady()
	return servePersistentDaemonWithVerifierConfig(
		listener,
		persistentDaemonFileTokenVerifier(token, paths.tokenFile),
		stderr,
		persistentDaemonServerConfig{emptyIdleTimeout: persistentDaemonEmptyIdleTimeout},
	)
}

func signalPersistentDaemonReady() {
	rawFD := strings.TrimSpace(os.Getenv(persistentDaemonReadyFDEnv))
	if rawFD == "" {
		return
	}
	fd, err := strconv.Atoi(rawFD)
	if err != nil || fd < 3 {
		return
	}
	file := os.NewFile(uintptr(fd), "cmux-persistent-daemon-ready")
	if file == nil {
		return
	}
	_, _ = file.WriteString("ready\n")
	_ = file.Close()
}

func servePersistentDaemon(listener net.Listener, token string, stderr io.Writer) error {
	return servePersistentDaemonWithVerifier(listener, persistentDaemonFixedTokenVerifier(token), stderr)
}

type persistentDaemonTokenVerifier func(string) bool

func persistentDaemonFixedTokenVerifier(token string) persistentDaemonTokenVerifier {
	return func(provided string) bool {
		return persistentDaemonTokensEqual(provided, token)
	}
}

func persistentDaemonFileTokenVerifier(initialToken string, tokenFile string) persistentDaemonTokenVerifier {
	return func(provided string) bool {
		token := initialToken
		if currentToken, err := readPersistentDaemonTokenFile(tokenFile); err == nil {
			token = currentToken
		}
		return persistentDaemonTokensEqual(provided, token)
	}
}

func persistentDaemonTokensEqual(provided string, token string) bool {
	provided = strings.TrimSpace(provided)
	token = strings.TrimSpace(token)
	return provided != "" &&
		token != "" &&
		subtle.ConstantTimeCompare([]byte(provided), []byte(token)) == 1
}

func servePersistentDaemonWithVerifier(listener net.Listener, verifier persistentDaemonTokenVerifier, stderr io.Writer) error {
	return servePersistentDaemonWithVerifierConfig(listener, verifier, stderr, persistentDaemonServerConfig{})
}

func servePersistentDaemonWithVerifierConfig(
	listener net.Listener,
	verifier persistentDaemonTokenVerifier,
	stderr io.Writer,
	config persistentDaemonServerConfig,
) error {
	hub := newWebSocketPTYHub(wsPTYServerConfig{}, stderr)
	defer hub.closeAll()
	var activeConnections int64
	var idleSince time.Time
	for {
		if config.emptyIdleTimeout > 0 {
			now := time.Now()
			isEmpty := atomic.LoadInt64(&activeConnections) == 0 && hub.activeSessionCount() == 0
			if isEmpty {
				if idleSince.IsZero() {
					idleSince = now
				}
				remaining := config.emptyIdleTimeout - now.Sub(idleSince)
				if remaining <= 0 {
					return nil
				}
				setPersistentDaemonAcceptDeadline(listener, now.Add(minDuration(
					remaining,
					persistentDaemonAcceptPollStep(config),
				)))
			} else {
				idleSince = time.Time{}
				setPersistentDaemonAcceptDeadline(listener, now.Add(persistentDaemonAcceptPollStep(config)))
			}
		}
		conn, err := listener.Accept()
		if err != nil {
			if isTimeoutError(err) {
				continue
			}
			if isClosedListenerError(err) {
				return nil
			}
			return err
		}
		atomic.AddInt64(&activeConnections, 1)
		go func() {
			defer atomic.AddInt64(&activeConnections, -1)
			handlePersistentDaemonConn(conn, verifier, hub)
		}()
	}
}

func persistentDaemonAcceptPollStep(config persistentDaemonServerConfig) time.Duration {
	if config.acceptPollStep > 0 {
		return config.acceptPollStep
	}
	return persistentDaemonEmptyIdlePollStep
}

type deadlineListener interface {
	SetDeadline(time.Time) error
}

func setPersistentDaemonAcceptDeadline(listener net.Listener, deadline time.Time) {
	if deadlineListener, ok := listener.(deadlineListener); ok {
		_ = deadlineListener.SetDeadline(deadline)
	}
}

func minDuration(a time.Duration, b time.Duration) time.Duration {
	if a < b {
		return a
	}
	return b
}

func isTimeoutError(err error) bool {
	var netErr net.Error
	return errors.As(err, &netErr) && netErr.Timeout()
}

func isClosedListenerError(err error) bool {
	if err == nil {
		return false
	}
	if errors.Is(err, net.ErrClosed) {
		return true
	}
	return strings.Contains(err.Error(), "use of closed network connection")
}

func handlePersistentDaemonConn(conn net.Conn, verifier persistentDaemonTokenVerifier, hub *wsPTYHub) {
	handlePersistentDaemonConnWithAuthTimeout(conn, verifier, hub, persistentDaemonAuthTimeout)
}

func handlePersistentDaemonConnWithAuthTimeout(conn net.Conn, verifier persistentDaemonTokenVerifier, hub *wsPTYHub, timeout time.Duration) {
	defer conn.Close()
	if timeout > 0 {
		if err := conn.SetDeadline(time.Now().Add(timeout)); err != nil {
			return
		}
	}
	reader := bufio.NewReaderSize(conn, 64*1024)
	writer := &stdioFrameWriter{writer: bufio.NewWriter(conn)}
	if !authenticatePersistentDaemonConn(reader, writer, verifier) {
		return
	}
	if timeout > 0 {
		if err := conn.SetDeadline(time.Time{}); err != nil {
			return
		}
	}
	_ = runRPCServerWithReader(reader, writer, hub, false)
}

func authenticatePersistentDaemonConn(reader *bufio.Reader, writer *stdioFrameWriter, verifier persistentDaemonTokenVerifier) bool {
	line, oversized, err := readRPCFrame(reader, maxRPCFrameBytes)
	if err != nil || oversized {
		_ = writer.writeResponse(rpcResponse{
			OK: false,
			Error: &rpcError{
				Code:    "unauthorized",
				Message: "persistent daemon authentication required",
			},
		})
		return false
	}
	line = bytes.TrimSuffix(line, []byte{'\n'})
	line = bytes.TrimSuffix(line, []byte{'\r'})
	var req rpcRequest
	if err := json.Unmarshal(line, &req); err != nil {
		_ = writer.writeResponse(rpcResponse{
			OK: false,
			Error: &rpcError{
				Code:    "invalid_request",
				Message: "invalid JSON request",
			},
		})
		return false
	}
	if req.Method != persistentDaemonAuthMethod {
		_ = writer.writeResponse(rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "unauthorized",
				Message: "persistent daemon authentication required",
			},
		})
		return false
	}
	provided, _ := getStringParam(req.Params, "token")
	if !verifier(provided) {
		_ = writer.writeResponse(rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "unauthorized",
				Message: "invalid persistent daemon token",
			},
		})
		return false
	}
	_ = writer.writeResponse(rpcResponse{
		ID: req.ID,
		OK: true,
		Result: map[string]any{
			"authenticated": true,
		},
	})
	return true
}

func runRPCServerWithReader(reader *bufio.Reader, writer *stdioFrameWriter, ptyHub *wsPTYHub, ownsPTYHub bool) error {
	server := &rpcServer{
		nextStreamID:  1,
		nextSessionID: 1,
		streams:       map[string]*streamState{},
		sessions:      map[string]*sessionState{},
		ptyHub:        ptyHub,
		ownsPTYHub:    ownsPTYHub,
		frameWriter:   writer,
	}
	defer server.closeAll()
	defer writer.writer.Flush()

	for {
		line, oversized, readErr := readRPCFrame(reader, maxRPCFrameBytes)
		if readErr != nil {
			if errors.Is(readErr, io.EOF) {
				return nil
			}
			return readErr
		}
		if oversized {
			if err := writer.writeResponse(rpcResponse{
				OK: false,
				Error: &rpcError{
					Code:    "invalid_request",
					Message: "request frame exceeds maximum size",
				},
			}); err != nil {
				return err
			}
			continue
		}
		line = bytes.TrimSuffix(line, []byte{'\n'})
		line = bytes.TrimSuffix(line, []byte{'\r'})
		if len(line) == 0 {
			continue
		}

		var req rpcRequest
		if err := json.Unmarshal(line, &req); err != nil {
			if err := writer.writeResponse(rpcResponse{
				OK: false,
				Error: &rpcError{
					Code:    "invalid_request",
					Message: "invalid JSON request",
				},
			}); err != nil {
				return err
			}
			continue
		}

		if err := server.handleRequestAndWriteResponse(req); err != nil {
			return err
		}
	}
}

func dialPersistentDaemon(socketPath string, token string) (net.Conn, error) {
	conn, err := net.DialTimeout("unix", socketPath, 2*time.Second)
	if err != nil {
		return nil, err
	}
	if err := authenticatePersistentDaemonClient(conn, token); err != nil {
		_ = conn.Close()
		return nil, err
	}
	return conn, nil
}

func authenticatePersistentDaemonClient(conn net.Conn, token string) error {
	return authenticatePersistentDaemonClientWithTimeout(conn, token, persistentDaemonAuthTimeout)
}

func authenticatePersistentDaemonClientWithTimeout(conn net.Conn, token string, timeout time.Duration) error {
	if timeout > 0 {
		if err := conn.SetDeadline(time.Now().Add(timeout)); err != nil {
			return err
		}
		defer conn.SetDeadline(time.Time{})
	}

	writer := bufio.NewWriter(conn)
	request := rpcRequest{
		ID:     "auth",
		Method: persistentDaemonAuthMethod,
		Params: map[string]any{
			"token": token,
		},
	}
	data, err := json.Marshal(request)
	if err != nil {
		return err
	}
	if _, err := writer.Write(data); err != nil {
		return err
	}
	if err := writer.WriteByte('\n'); err != nil {
		return err
	}
	if err := writer.Flush(); err != nil {
		return err
	}
	reader := bufio.NewReaderSize(conn, 64*1024)
	line, oversized, err := readRPCFrame(reader, maxRPCFrameBytes)
	if err != nil {
		return err
	}
	if oversized {
		return errors.New("persistent daemon auth response exceeded maximum size")
	}
	var resp rpcResponse
	if err := json.Unmarshal(bytes.TrimSpace(line), &resp); err != nil {
		return err
	}
	if !resp.OK {
		message := "persistent daemon authentication failed"
		if resp.Error != nil && strings.TrimSpace(resp.Error.Message) != "" {
			message = strings.TrimSpace(resp.Error.Message)
		}
		return fmt.Errorf("%w: %s", errPersistentDaemonAuthFailed, message)
	}
	return nil
}

func setTCPNoDelay(conn net.Conn) {
	tcpConn, ok := conn.(*net.TCPConn)
	if !ok {
		return
	}
	_ = tcpConn.SetNoDelay(true)
}

func readRPCFrame(reader *bufio.Reader, maxBytes int) ([]byte, bool, error) {
	frame := make([]byte, 0, 1024)
	for {
		chunk, err := reader.ReadSlice('\n')
		if len(chunk) > 0 {
			if len(frame)+len(chunk) > maxBytes {
				if errors.Is(err, bufio.ErrBufferFull) {
					if drainErr := discardUntilNewline(reader); drainErr != nil && !errors.Is(drainErr, io.EOF) {
						return nil, false, drainErr
					}
				}
				return nil, true, nil
			}
			frame = append(frame, chunk...)
		}

		if err == nil {
			return frame, false, nil
		}
		if errors.Is(err, bufio.ErrBufferFull) {
			continue
		}
		if errors.Is(err, io.EOF) {
			if len(frame) == 0 {
				return nil, false, io.EOF
			}
			return frame, false, nil
		}
		return nil, false, err
	}
}

func discardUntilNewline(reader *bufio.Reader) error {
	for {
		_, err := reader.ReadSlice('\n')
		if err == nil || errors.Is(err, io.EOF) {
			return err
		}
		if errors.Is(err, bufio.ErrBufferFull) {
			continue
		}
		return err
	}
}

func (w *stdioFrameWriter) writeResponse(resp rpcResponse) error {
	return w.writeJSONFrame(resp)
}

func (w *stdioFrameWriter) writeEvent(event rpcEvent) error {
	return w.writeJSONFrame(event)
}

func (w *stdioFrameWriter) writeJSONFrame(payload any) error {
	data, err := json.Marshal(payload)
	if err != nil {
		return err
	}
	w.mu.Lock()
	defer w.mu.Unlock()
	if _, err := w.writer.Write(data); err != nil {
		return err
	}
	if err := w.writer.WriteByte('\n'); err != nil {
		return err
	}
	return w.writer.Flush()
}

func (s *rpcServer) handleRequest(req rpcRequest) rpcResponse {
	if req.Method == "" {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "invalid_request",
				Message: "method is required",
			},
		}
	}

	switch req.Method {
	case "hello":
		return rpcResponse{
			ID: req.ID,
			OK: true,
			Result: map[string]any{
				"name":    "cmuxd-remote",
				"version": version,
				"capabilities": []string{
					"session.basic",
					"session.resize.min",
					"proxy.http_connect",
					"proxy.socks5",
					"proxy.stream",
					"proxy.stream.push",
					"pty.session",
					"pty.session.token",
					"pty.session.persistent_daemon",
					"pty.write.notification",
					"pty.resize.notification",
					"pty.input.seq_ack",
					"cli.bridge",
				},
			},
		}
	case "ping":
		return rpcResponse{
			ID: req.ID,
			OK: true,
			Result: map[string]any{
				"pong": true,
			},
		}
	case "proxy.open":
		return s.handleProxyOpen(req)
	case "proxy.close":
		return s.handleProxyClose(req)
	case "proxy.write":
		return s.handleProxyWrite(req)
	case "proxy.stream.subscribe":
		return s.handleProxyStreamSubscribe(req)
	case "session.open":
		return s.handleSessionOpen(req)
	case "session.close":
		return s.handleSessionClose(req)
	case "session.attach":
		return s.handleSessionAttach(req)
	case "session.resize":
		return s.handleSessionResize(req)
	case "session.detach":
		return s.handleSessionDetach(req)
	case "session.status":
		return s.handleSessionStatus(req)
	case "pty.attach":
		return s.handlePTYAttach(req)
	case "pty.write":
		return s.handlePTYWrite(req)
	case "pty.resize":
		return s.handlePTYResize(req)
	case "pty.detach":
		return s.handlePTYDetach(req)
	case "pty.close":
		return s.handlePTYClose(req)
	case "pty.list":
		return s.handlePTYList(req)
	case "cli.response":
		return s.handleCLIResponse(req)
	default:
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "method_not_found",
				Message: fmt.Sprintf("unknown method %q", req.Method),
			},
		}
	}
}

func (s *rpcServer) handleRequestAndWriteResponse(req rpcRequest) error {
	resp := s.handleRequest(req)
	if !rpcRequestExpectsResponse(req) {
		return s.handleNotificationResponse(req, resp)
	}
	return s.frameWriter.writeResponse(resp)
}

func rpcRequestExpectsResponse(req rpcRequest) bool {
	// Only selected PTY attachment operations use JSON-RPC notification
	// semantics; all other id-less requests still get a response for compatibility.
	return !rpcRequestIsPTYAttachmentNotification(req)
}

func rpcRequestIsPTYAttachmentNotification(req rpcRequest) bool {
	return !req.HasID && (req.Method == "pty.write" || req.Method == "pty.resize")
}

func (s *rpcServer) handleNotificationResponse(req rpcRequest, resp rpcResponse) error {
	if !rpcRequestIsPTYAttachmentNotification(req) || resp.OK {
		return nil
	}
	if s.frameWriter == nil {
		detail := "unknown error"
		if resp.Error != nil {
			detail = strings.TrimSpace(resp.Error.Code)
			if message := strings.TrimSpace(resp.Error.Message); message != "" {
				if detail != "" {
					detail += ": "
				}
				detail += message
			}
		}
		_, _ = fmt.Fprintf(os.Stderr, "cmuxd-remote: %s notification failed without response writer: %s\n", req.Method, detail)
		return nil
	}
	sessionID, attachmentID, attachmentToken, badResp := parsePTYAttachmentIdentity(req, req.Method)
	if badResp != nil || strings.TrimSpace(attachmentToken) == "" {
		return nil
	}
	detail := "PTY operation failed"
	if req.Method == "pty.write" {
		detail = "PTY write failed"
	} else if req.Method == "pty.resize" {
		detail = "PTY resize failed"
	}
	if resp.Error != nil && strings.TrimSpace(resp.Error.Message) != "" {
		detail = strings.TrimSpace(resp.Error.Message)
	}
	err := s.frameWriter.writeEvent(rpcEvent{
		Event:           "pty.error",
		SessionID:       sessionID,
		AttachmentID:    attachmentID,
		AttachmentToken: attachmentToken,
		Error:           detail,
		Message:         detail,
	})
	if req.Method == "pty.write" && resp.Error != nil && s.ptyHub != nil &&
		(resp.Error.Code == "pty_input_queue_full" || resp.Error.Code == "pty_input_seq_gap") {
		s.ptyHub.detachByID(sessionID, attachmentID, attachmentToken)
	}
	return err
}

func (s *rpcServer) handleProxyOpen(req rpcRequest) rpcResponse {
	host, ok := getStringParam(req.Params, "host")
	if !ok || host == "" {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "invalid_params",
				Message: "proxy.open requires host",
			},
		}
	}
	port, ok := getIntParam(req.Params, "port")
	if !ok || port <= 0 || port > 65535 {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "invalid_params",
				Message: "proxy.open requires port in range 1-65535",
			},
		}
	}

	timeoutMs := 10000
	if parsed, hasTimeout := getIntParam(req.Params, "timeout_ms"); hasTimeout && parsed >= 0 {
		timeoutMs = parsed
	}

	conn, err := net.DialTimeout(
		"tcp",
		net.JoinHostPort(host, strconv.Itoa(port)),
		time.Duration(timeoutMs)*time.Millisecond,
	)
	if err != nil {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "open_failed",
				Message: err.Error(),
			},
		}
	}
	setTCPNoDelay(conn)

	s.mu.Lock()
	streamID := fmt.Sprintf("s-%d", s.nextStreamID)
	s.nextStreamID++
	s.streams[streamID] = &streamState{conn: conn}
	s.mu.Unlock()

	return rpcResponse{
		ID: req.ID,
		OK: true,
		Result: map[string]any{
			"stream_id": streamID,
		},
	}
}

func (s *rpcServer) handleProxyClose(req rpcRequest) rpcResponse {
	streamID, ok := getStringParam(req.Params, "stream_id")
	if !ok || streamID == "" {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "invalid_params",
				Message: "proxy.close requires stream_id",
			},
		}
	}

	s.mu.Lock()
	state, exists := s.streams[streamID]
	if exists {
		delete(s.streams, streamID)
	}
	s.mu.Unlock()

	if !exists {
		return rpcResponse{
			ID: req.ID,
			OK: true,
			Result: map[string]any{
				"closed": true,
			},
		}
	}

	_ = state.conn.Close()
	return rpcResponse{
		ID: req.ID,
		OK: true,
		Result: map[string]any{
			"closed": true,
		},
	}
}

func (s *rpcServer) handleProxyWrite(req rpcRequest) rpcResponse {
	streamID, ok := getStringParam(req.Params, "stream_id")
	if !ok || streamID == "" {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "invalid_params",
				Message: "proxy.write requires stream_id",
			},
		}
	}
	dataBase64, ok := getStringParam(req.Params, "data_base64")
	if !ok {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "invalid_params",
				Message: "proxy.write requires data_base64",
			},
		}
	}
	payload, err := base64.StdEncoding.DecodeString(dataBase64)
	if err != nil {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "invalid_params",
				Message: "data_base64 must be valid base64",
			},
		}
	}

	state, found := s.getStream(streamID)
	if !found {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "not_found",
				Message: "stream not found",
			},
		}
	}
	conn := state.conn

	timeoutMs := 8000
	if parsed, hasTimeout := getIntParam(req.Params, "timeout_ms"); hasTimeout {
		timeoutMs = parsed
	}
	if timeoutMs > 0 {
		if err := conn.SetWriteDeadline(time.Now().Add(time.Duration(timeoutMs) * time.Millisecond)); err != nil {
			return rpcResponse{
				ID: req.ID,
				OK: false,
				Error: &rpcError{
					Code:    "stream_error",
					Message: err.Error(),
				},
			}
		}
		defer conn.SetWriteDeadline(time.Time{})
	}

	total := 0
	for total < len(payload) {
		written, writeErr := conn.Write(payload[total:])
		if written == 0 && writeErr == nil {
			return rpcResponse{
				ID: req.ID,
				OK: false,
				Error: &rpcError{
					Code:    "stream_error",
					Message: "write made no progress",
				},
			}
		}
		total += written
		if writeErr != nil {
			return rpcResponse{
				ID: req.ID,
				OK: false,
				Error: &rpcError{
					Code:    "stream_error",
					Message: writeErr.Error(),
				},
			}
		}
	}

	return rpcResponse{
		ID: req.ID,
		OK: true,
		Result: map[string]any{
			"written": total,
		},
	}
}

func (s *rpcServer) handleProxyStreamSubscribe(req rpcRequest) rpcResponse {
	streamID, ok := getStringParam(req.Params, "stream_id")
	if !ok || streamID == "" {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "invalid_params",
				Message: "proxy.stream.subscribe requires stream_id",
			},
		}
	}

	s.mu.Lock()
	state, found := s.streams[streamID]
	if !found {
		s.mu.Unlock()
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "not_found",
				Message: "stream not found",
			},
		}
	}
	alreadySubscribed := state.readerStarted
	if !alreadySubscribed {
		state.readerStarted = true
	}
	conn := state.conn
	s.mu.Unlock()

	if !alreadySubscribed {
		go s.streamPump(streamID, conn)
	}

	return rpcResponse{
		ID: req.ID,
		OK: true,
		Result: map[string]any{
			"subscribed":         true,
			"already_subscribed": alreadySubscribed,
		},
	}
}

func (s *rpcServer) handleSessionOpen(req rpcRequest) rpcResponse {
	sessionID, _ := getStringParam(req.Params, "session_id")

	s.mu.Lock()
	defer s.mu.Unlock()

	if sessionID == "" {
		sessionID = fmt.Sprintf("sess-%d", s.nextSessionID)
		s.nextSessionID++
	}

	session, exists := s.sessions[sessionID]
	if !exists {
		session = &sessionState{
			attachments: map[string]sessionAttachment{},
		}
		s.sessions[sessionID] = session
	}

	return rpcResponse{
		ID:     req.ID,
		OK:     true,
		Result: sessionSnapshot(sessionID, session),
	}
}

func (s *rpcServer) handleSessionClose(req rpcRequest) rpcResponse {
	sessionID, ok := getStringParam(req.Params, "session_id")
	if !ok || sessionID == "" {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "invalid_params",
				Message: "session.close requires session_id",
			},
		}
	}

	s.mu.Lock()
	_, exists := s.sessions[sessionID]
	if exists {
		delete(s.sessions, sessionID)
	}
	s.mu.Unlock()

	if !exists {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "not_found",
				Message: "session not found",
			},
		}
	}

	return rpcResponse{
		ID: req.ID,
		OK: true,
		Result: map[string]any{
			"session_id": sessionID,
			"closed":     true,
		},
	}
}

func (s *rpcServer) handleSessionAttach(req rpcRequest) rpcResponse {
	sessionID, attachmentID, _, cols, rows, badResp := parseSessionAttachmentParams(req, "session.attach")
	if badResp != nil {
		return *badResp
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	session, exists := s.sessions[sessionID]
	if !exists {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "not_found",
				Message: "session not found",
			},
		}
	}

	session.attachments[attachmentID] = sessionAttachment{
		Cols:      cols,
		Rows:      rows,
		UpdatedAt: time.Now().UTC(),
	}
	recomputeSessionSize(session)

	return rpcResponse{
		ID:     req.ID,
		OK:     true,
		Result: sessionSnapshot(sessionID, session),
	}
}

func (s *rpcServer) handleSessionResize(req rpcRequest) rpcResponse {
	sessionID, attachmentID, _, cols, rows, badResp := parseSessionAttachmentParams(req, "session.resize")
	if badResp != nil {
		return *badResp
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	session, exists := s.sessions[sessionID]
	if !exists {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "not_found",
				Message: "session not found",
			},
		}
	}
	if _, exists := session.attachments[attachmentID]; !exists {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "not_found",
				Message: "attachment not found",
			},
		}
	}

	session.attachments[attachmentID] = sessionAttachment{
		Cols:      cols,
		Rows:      rows,
		UpdatedAt: time.Now().UTC(),
	}
	recomputeSessionSize(session)

	return rpcResponse{
		ID:     req.ID,
		OK:     true,
		Result: sessionSnapshot(sessionID, session),
	}
}

func (s *rpcServer) handleSessionDetach(req rpcRequest) rpcResponse {
	sessionID, ok := getStringParam(req.Params, "session_id")
	if !ok || sessionID == "" {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "invalid_params",
				Message: "session.detach requires session_id",
			},
		}
	}
	attachmentID, ok := getStringParam(req.Params, "attachment_id")
	if !ok || attachmentID == "" {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "invalid_params",
				Message: "session.detach requires attachment_id",
			},
		}
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	session, exists := s.sessions[sessionID]
	if !exists {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "not_found",
				Message: "session not found",
			},
		}
	}
	if _, exists := session.attachments[attachmentID]; !exists {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "not_found",
				Message: "attachment not found",
			},
		}
	}

	delete(session.attachments, attachmentID)
	recomputeSessionSize(session)

	return rpcResponse{
		ID:     req.ID,
		OK:     true,
		Result: sessionSnapshot(sessionID, session),
	}
}

func (s *rpcServer) handleSessionStatus(req rpcRequest) rpcResponse {
	sessionID, ok := getStringParam(req.Params, "session_id")
	if !ok || sessionID == "" {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "invalid_params",
				Message: "session.status requires session_id",
			},
		}
	}

	s.mu.Lock()
	defer s.mu.Unlock()

	session, exists := s.sessions[sessionID]
	if !exists {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "not_found",
				Message: "session not found",
			},
		}
	}

	return rpcResponse{
		ID:     req.ID,
		OK:     true,
		Result: sessionSnapshot(sessionID, session),
	}
}

func (s *rpcServer) handlePTYAttach(req rpcRequest) rpcResponse {
	sessionID, ok := getStringParam(req.Params, "session_id")
	if !ok || strings.TrimSpace(sessionID) == "" {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "invalid_params",
				Message: "pty.attach requires session_id",
			},
		}
	}
	attachmentID, _ := getStringParam(req.Params, "attachment_id")
	attachmentToken, _ := getStringParam(req.Params, "client_attachment_token")
	attachmentToken = strings.TrimSpace(attachmentToken)
	if attachmentToken == "" {
		return missingPTYAttachmentTokenResponse(req, "pty.attach")
	}
	cols, ok := getIntParam(req.Params, "cols")
	if !ok || cols <= 0 {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "invalid_params",
				Message: "pty.attach requires cols > 0",
			},
		}
	}
	rows, ok := getIntParam(req.Params, "rows")
	if !ok || rows <= 0 {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "invalid_params",
				Message: "pty.attach requires rows > 0",
			},
		}
	}
	command, _ := getStringParam(req.Params, "command")
	requireExisting, _ := getBoolParam(req.Params, "require_existing")
	inputSeqAck, _ := getBoolParam(req.Params, "input_seq_ack")

	hub := s.ptyHub
	if hub == nil {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "unavailable",
				Message: "PTY hub is not available",
			},
		}
	}
	attachment, attachmentCtx, sessionDone, err := hub.attachRPC(
		context.Background(),
		sessionID,
		attachmentID,
		cols,
		rows,
		command,
		attachmentToken,
		requireExisting,
		inputSeqAck,
	)
	if err != nil {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    ptyAttachErrorCode(requireExisting),
				Message: err.Error(),
			},
		}
	}
	s.trackPTYAttachment(attachment)
	go s.ptyAttachmentPump(attachmentCtx, attachment, sessionDone)

	return rpcResponse{
		ID: req.ID,
		OK: true,
		Result: map[string]any{
			"session_id":       strings.TrimSpace(sessionID),
			"attachment_id":    attachment.id,
			"attachment_token": attachment.clientToken,
			"attached":         true,
		},
	}
}

func ptyAttachErrorCode(requireExisting bool) string {
	if requireExisting {
		return "pty_session_not_found"
	}
	return "pty_start_failed"
}

func (s *rpcServer) handlePTYWrite(req rpcRequest) rpcResponse {
	sessionID, attachmentID, attachmentToken, badResp := parsePTYAttachmentIdentity(req, "pty.write")
	if badResp != nil {
		return *badResp
	}
	if attachmentToken == "" {
		return missingPTYAttachmentTokenResponse(req, "pty.write")
	}
	dataBase64, ok := getStringParam(req.Params, "data_base64")
	if !ok {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "invalid_params",
				Message: "pty.write requires data_base64",
			},
		}
	}
	payload, err := base64.StdEncoding.DecodeString(dataBase64)
	if err != nil {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "invalid_params",
				Message: "data_base64 must be valid base64",
			},
		}
	}
	writeStatus := wsPTYInputWriteNotFound
	var seq uint64
	var hasSeq bool
	if _, provided := req.Params["seq"]; provided {
		parsedSeq, ok := getIntParam(req.Params, "seq")
		if !ok || parsedSeq < 0 {
			return rpcResponse{
				ID: req.ID,
				OK: false,
				Error: &rpcError{
					Code:    "invalid_params",
					Message: "seq must be a non-negative integer",
				},
			}
		}
		seq = uint64(parsedSeq)
		hasSeq = true
	}
	writeResult := wsPTYInputWriteResult{status: wsPTYInputWriteNotFound}
	if s.ptyHub != nil {
		writeResult = s.ptyHub.writeInputByIDWithSeq(sessionID, attachmentID, attachmentToken, payload, seq, hasSeq)
		writeStatus = writeResult.status
	}
	if writeStatus == wsPTYInputWriteSeqGap {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "pty_input_seq_gap",
				Message: fmt.Sprintf("PTY input sequence gap: got %d, want %d", writeResult.got, writeResult.want),
			},
		}
	}
	if writeStatus == wsPTYInputWriteQueueFull {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "pty_input_queue_full",
				Message: "PTY input queue is full",
			},
		}
	}
	if writeStatus != wsPTYInputWriteOK {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "not_found",
				Message: "PTY attachment not found",
			},
		}
	}
	return rpcResponse{
		ID: req.ID,
		OK: true,
		Result: map[string]any{
			"written": len(payload),
		},
	}
}

func (s *rpcServer) handlePTYResize(req rpcRequest) rpcResponse {
	sessionID, attachmentID, attachmentToken, cols, rows, badResp := parseSessionAttachmentParams(req, "pty.resize")
	if badResp != nil {
		return *badResp
	}
	if attachmentToken == "" {
		return missingPTYAttachmentTokenResponse(req, "pty.resize")
	}
	if s.ptyHub == nil || !s.ptyHub.resizeByID(sessionID, attachmentID, attachmentToken, cols, rows) {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "not_found",
				Message: "PTY attachment not found",
			},
		}
	}
	return rpcResponse{
		ID: req.ID,
		OK: true,
		Result: map[string]any{
			"resized": true,
		},
	}
}

func (s *rpcServer) handlePTYDetach(req rpcRequest) rpcResponse {
	sessionID, attachmentID, attachmentToken, badResp := parsePTYAttachmentIdentity(req, "pty.detach")
	if badResp != nil {
		return *badResp
	}
	if attachmentToken == "" {
		return missingPTYAttachmentTokenResponse(req, "pty.detach")
	}
	if s.ptyHub == nil || !s.ptyHub.detachByID(sessionID, attachmentID, attachmentToken) {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "not_found",
				Message: "PTY attachment not found",
			},
		}
	}
	return rpcResponse{
		ID: req.ID,
		OK: true,
		Result: map[string]any{
			"detached": true,
		},
	}
}

func (s *rpcServer) handlePTYClose(req rpcRequest) rpcResponse {
	sessionID, ok := getStringParam(req.Params, "session_id")
	if !ok || strings.TrimSpace(sessionID) == "" {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "invalid_params",
				Message: "pty.close requires session_id",
			},
		}
	}
	if s.ptyHub == nil || !s.ptyHub.closeSessionByID(sessionID) {
		return rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "not_found",
				Message: "PTY session not found",
			},
		}
	}
	return rpcResponse{
		ID: req.ID,
		OK: true,
		Result: map[string]any{
			"session_id": strings.TrimSpace(sessionID),
			"closed":     true,
		},
	}
}

func (s *rpcServer) handlePTYList(req rpcRequest) rpcResponse {
	if s.ptyHub == nil {
		return rpcResponse{
			ID: req.ID,
			OK: true,
			Result: map[string]any{
				"sessions": []map[string]any{},
			},
		}
	}
	return rpcResponse{
		ID: req.ID,
		OK: true,
		Result: map[string]any{
			"sessions": s.ptyHub.sessionSnapshots(),
		},
	}
}

func (s *rpcServer) ptyAttachmentPump(ctx context.Context, attachment *wsPTYAttachment, sessionDone <-chan struct{}) {
	defer s.untrackPTYAttachment(attachment)
	for {
		select {
		case <-ctx.Done():
			_ = s.frameWriter.writeEvent(rpcPTYExitEvent(attachment))
			return
		case <-sessionDone:
			for {
				select {
				case frame := <-attachment.send:
					if err := s.frameWriter.writeEvent(rpcPTYEventForFrame(attachment, frame)); err != nil {
						if s.ptyHub != nil {
							s.ptyHub.dropAttachment(attachment)
						}
						return
					}
				default:
					_ = s.frameWriter.writeEvent(rpcPTYExitEvent(attachment))
					return
				}
			}
		case frame := <-attachment.send:
			if err := s.frameWriter.writeEvent(rpcPTYEventForFrame(attachment, frame)); err != nil {
				if s.ptyHub != nil {
					s.ptyHub.dropAttachment(attachment)
				}
				return
			}
		}
	}
}

func (s *rpcServer) trackPTYAttachment(attachment *wsPTYAttachment) {
	if attachment == nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.ptyAttachments == nil {
		s.ptyAttachments = map[string]*wsPTYAttachment{}
	}
	s.ptyAttachments[rpcPTYAttachmentKey(attachment)] = attachment
}

func (s *rpcServer) untrackPTYAttachment(attachment *wsPTYAttachment) {
	if attachment == nil {
		return
	}
	s.mu.Lock()
	defer s.mu.Unlock()
	key := rpcPTYAttachmentKey(attachment)
	if current := s.ptyAttachments[key]; current == attachment {
		delete(s.ptyAttachments, key)
	}
}

func rpcPTYAttachmentKey(attachment *wsPTYAttachment) string {
	if attachment == nil {
		return ""
	}
	return fmt.Sprintf(
		"%d:%s:%d:%s:%s",
		attachment.sessionKey.kind,
		attachment.sessionKey.sessionID,
		attachment.sessionKey.anonymousID,
		attachment.id,
		attachment.clientToken,
	)
}

func missingPTYAttachmentTokenResponse(req rpcRequest, method string) rpcResponse {
	return rpcResponse{
		ID: req.ID,
		OK: false,
		Error: &rpcError{
			Code:    "invalid_params",
			Message: method + " requires client_attachment_token",
		},
	}
}

func parseSessionAttachmentParams(req rpcRequest, method string) (sessionID string, attachmentID string, attachmentToken string, cols int, rows int, badResp *rpcResponse) {
	sessionID, attachmentID, attachmentToken, identityResp := parsePTYAttachmentIdentity(req, method)
	if identityResp != nil {
		return "", "", "", 0, 0, identityResp
	}

	cols, ok := getIntParam(req.Params, "cols")
	if !ok || cols <= 0 {
		resp := rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "invalid_params",
				Message: method + " requires cols > 0",
			},
		}
		return "", "", "", 0, 0, &resp
	}
	rows, ok = getIntParam(req.Params, "rows")
	if !ok || rows <= 0 {
		resp := rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "invalid_params",
				Message: method + " requires rows > 0",
			},
		}
		return "", "", "", 0, 0, &resp
	}

	return sessionID, attachmentID, attachmentToken, cols, rows, nil
}

func parsePTYAttachmentIdentity(req rpcRequest, method string) (sessionID string, attachmentID string, attachmentToken string, badResp *rpcResponse) {
	sessionID, ok := getStringParam(req.Params, "session_id")
	if !ok || strings.TrimSpace(sessionID) == "" {
		resp := rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "invalid_params",
				Message: method + " requires session_id",
			},
		}
		return "", "", "", &resp
	}
	attachmentID, ok = getStringParam(req.Params, "attachment_id")
	if !ok || strings.TrimSpace(attachmentID) == "" {
		resp := rpcResponse{
			ID: req.ID,
			OK: false,
			Error: &rpcError{
				Code:    "invalid_params",
				Message: method + " requires attachment_id",
			},
		}
		return "", "", "", &resp
	}
	attachmentToken, _ = getStringParam(req.Params, "client_attachment_token")
	return strings.TrimSpace(sessionID), strings.TrimSpace(attachmentID), strings.TrimSpace(attachmentToken), nil
}

func recomputeSessionSize(session *sessionState) {
	if len(session.attachments) == 0 {
		session.effectiveCols = session.lastKnownCols
		session.effectiveRows = session.lastKnownRows
		return
	}

	minCols := 0
	minRows := 0
	for _, attachment := range session.attachments {
		if minCols == 0 || attachment.Cols < minCols {
			minCols = attachment.Cols
		}
		if minRows == 0 || attachment.Rows < minRows {
			minRows = attachment.Rows
		}
	}

	session.effectiveCols = minCols
	session.effectiveRows = minRows
	session.lastKnownCols = minCols
	session.lastKnownRows = minRows
}

func sessionSnapshot(sessionID string, session *sessionState) map[string]any {
	attachmentIDs := make([]string, 0, len(session.attachments))
	for attachmentID := range session.attachments {
		attachmentIDs = append(attachmentIDs, attachmentID)
	}
	sort.Strings(attachmentIDs)

	attachments := make([]map[string]any, 0, len(attachmentIDs))
	for _, attachmentID := range attachmentIDs {
		attachment := session.attachments[attachmentID]
		attachments = append(attachments, map[string]any{
			"attachment_id": attachmentID,
			"cols":          attachment.Cols,
			"rows":          attachment.Rows,
			"updated_at":    attachment.UpdatedAt.Format(time.RFC3339Nano),
		})
	}

	return map[string]any{
		"session_id":      sessionID,
		"attachments":     attachments,
		"effective_cols":  session.effectiveCols,
		"effective_rows":  session.effectiveRows,
		"last_known_cols": session.lastKnownCols,
		"last_known_rows": session.lastKnownRows,
	}
}

func (s *rpcServer) getStream(streamID string) (*streamState, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	state, ok := s.streams[streamID]
	return state, ok
}

func (s *rpcServer) dropStream(streamID string) {
	s.mu.Lock()
	state, ok := s.streams[streamID]
	if ok {
		delete(s.streams, streamID)
	}
	s.mu.Unlock()
	if ok {
		_ = state.conn.Close()
	}
}

func (s *rpcServer) closeAll() {
	s.mu.Lock()
	streams := make([]net.Conn, 0, len(s.streams))
	for id, state := range s.streams {
		delete(s.streams, id)
		streams = append(streams, state.conn)
	}
	for id := range s.sessions {
		delete(s.sessions, id)
	}
	ptyAttachments := make([]*wsPTYAttachment, 0, len(s.ptyAttachments))
	for id, attachment := range s.ptyAttachments {
		delete(s.ptyAttachments, id)
		ptyAttachments = append(ptyAttachments, attachment)
	}
	s.mu.Unlock()
	for _, conn := range streams {
		_ = conn.Close()
	}
	for _, attachment := range ptyAttachments {
		if s.ptyHub != nil {
			s.ptyHub.dropAttachment(attachment)
		} else {
			attachment.closeNow()
		}
	}
	if s.ownsPTYHub && s.ptyHub != nil {
		s.ptyHub.closeAll()
	}
}

func (s *rpcServer) streamPump(streamID string, conn net.Conn) {
	defer func() {
		if recovered := recover(); recovered != nil {
			_ = s.frameWriter.writeEvent(rpcEvent{
				Event:    "proxy.stream.error",
				StreamID: streamID,
				Error:    fmt.Sprintf("stream panic: %v", recovered),
			})
			s.dropStream(streamID)
		}
	}()

	buffer := make([]byte, 32768)
	for {
		n, readErr := conn.Read(buffer)
		data := append([]byte(nil), buffer[:max(0, n)]...)
		if len(data) > 0 {
			_ = s.frameWriter.writeEvent(rpcEvent{
				Event:      "proxy.stream.data",
				StreamID:   streamID,
				DataBase64: base64.StdEncoding.EncodeToString(data),
			})
		}

		if readErr == nil {
			if n == 0 {
				_ = s.frameWriter.writeEvent(rpcEvent{
					Event:    "proxy.stream.error",
					StreamID: streamID,
					Error:    "read made no progress",
				})
				s.dropStream(streamID)
				return
			}
			continue
		}

		if readErr == io.EOF {
			_ = s.frameWriter.writeEvent(rpcEvent{
				Event:      "proxy.stream.eof",
				StreamID:   streamID,
				DataBase64: "",
			})
		} else if !errors.Is(readErr, net.ErrClosed) {
			_ = s.frameWriter.writeEvent(rpcEvent{
				Event:    "proxy.stream.error",
				StreamID: streamID,
				Error:    readErr.Error(),
			})
		}

		s.dropStream(streamID)
		return
	}
}

func getStringParam(params map[string]any, key string) (string, bool) {
	if params == nil {
		return "", false
	}
	raw, ok := params[key]
	if !ok || raw == nil {
		return "", false
	}
	value, ok := raw.(string)
	return value, ok
}

func getIntParam(params map[string]any, key string) (int, bool) {
	if params == nil {
		return 0, false
	}
	raw, ok := params[key]
	if !ok || raw == nil {
		return 0, false
	}
	switch value := raw.(type) {
	case int:
		return value, true
	case int8:
		return int(value), true
	case int16:
		return int(value), true
	case int32:
		return int(value), true
	case int64:
		return int(value), true
	case uint:
		return int(value), true
	case uint8:
		return int(value), true
	case uint16:
		return int(value), true
	case uint32:
		return int(value), true
	case uint64:
		return int(value), true
	case float64:
		if math.Trunc(value) != value {
			return 0, false
		}
		return int(value), true
	case json.Number:
		n, err := value.Int64()
		if err != nil {
			return 0, false
		}
		return int(n), true
	default:
		return 0, false
	}
}

func getBoolParam(params map[string]any, key string) (bool, bool) {
	if params == nil {
		return false, false
	}
	raw, ok := params[key]
	if !ok || raw == nil {
		return false, false
	}
	value, ok := raw.(bool)
	return value, ok
}
