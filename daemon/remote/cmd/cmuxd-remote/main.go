package main

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strconv"
	"sync"
	"time"

	"github.com/manaflow-ai/cmux/daemon/remote/internal/direct"
	"github.com/manaflow-ai/cmux/daemon/remote/internal/rpc"
	"github.com/manaflow-ai/cmux/daemon/remote/internal/session"
	"github.com/manaflow-ai/cmux/daemon/remote/internal/terminal"
)

var version = "dev"

type daemonServer struct {
	mu           sync.Mutex
	nextStreamID uint64
	streams      map[string]net.Conn
	sessions     *session.Manager
	terminals    *terminal.Manager
}

func main() {
	// Busybox-style: if invoked as "cmux" (via symlink), act as CLI relay.
	base := filepath.Base(os.Args[0])
	if base == "cmux" {
		os.Exit(runCLI(os.Args[1:]))
	}
	os.Exit(run(os.Args[1:], os.Stdin, os.Stdout, os.Stderr))
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
		unixMode := fs.Bool("unix", false, "serve over a Unix socket")
		socketPath := fs.String("socket", "", "Unix socket path")
		tlsMode := fs.Bool("tls", false, "serve over TLS")
		listenAddr := fs.String("listen", "", "TLS listen address")
		serverID := fs.String("server-id", "", "server identifier for ticket verification")
		ticketSecret := fs.String("ticket-secret", "", "shared secret used to verify daemon tickets")
		certFile := fs.String("cert-file", "", "TLS certificate path")
		keyFile := fs.String("key-file", "", "TLS private key path")
		if err := fs.Parse(args[1:]); err != nil {
			return 2
		}
		modeCount := 0
		if *stdio {
			modeCount++
		}
		if *unixMode {
			modeCount++
		}
		if *tlsMode {
			modeCount++
		}
		if modeCount != 1 {
			_, _ = fmt.Fprintln(stderr, "serve requires exactly one of --stdio, --unix, or --tls")
			return 2
		}
		if *stdio {
			if err := runStdioServer(stdin, stdout); err != nil {
				_, _ = fmt.Fprintf(stderr, "serve failed: %v\n", err)
				return 1
			}
			return 0
		}
		if *unixMode {
			if err := runUnixServer(*socketPath); err != nil {
				_, _ = fmt.Fprintf(stderr, "serve failed: %v\n", err)
				return 1
			}
			return 0
		}
		if err := runTLSServer(direct.Config{
			ServerID:     *serverID,
			TicketSecret: []byte(*ticketSecret),
			CertFile:     *certFile,
			KeyFile:      *keyFile,
			ListenAddr:   *listenAddr,
		}); err != nil {
			_, _ = fmt.Fprintf(stderr, "serve failed: %v\n", err)
			return 1
		}
		return 0
	case "session":
		return runSessionCLI(args[1:])
	case "cli":
		return runCLI(args[1:])
	case "list", "ls", "attach", "status", "history", "kill", "new":
		return runSessionCLI(args)
	default:
		usage(stderr)
		return 2
	}
}

func usage(w io.Writer) {
	_, _ = fmt.Fprintln(w, "Usage:")
	_, _ = fmt.Fprintln(w, "  cmuxd-remote version")
	_, _ = fmt.Fprintln(w, "  cmuxd-remote serve --stdio")
	_, _ = fmt.Fprintln(w, "  cmuxd-remote serve --unix --socket <path>")
	_, _ = fmt.Fprintln(w, "  cmuxd-remote serve --tls --listen <addr> --server-id <id> --ticket-secret <secret> --cert-file <path> --key-file <path>")
	_, _ = fmt.Fprintln(w, "  cmuxd-remote session <command> [args...]")
	_, _ = fmt.Fprintln(w, "  cmuxd-remote cli <command> [args...]")
}

func runStdioServer(stdin io.Reader, stdout io.Writer) error {
	server := newDaemonServer()
	defer server.closeAll()
	return rpc.NewServer(server.handleRequest).Serve(stdin, stdout)
}

func runUnixServer(socketPath string) error {
	if socketPath == "" {
		return errors.New("unix server requires --socket")
	}
	if err := os.MkdirAll(filepath.Dir(socketPath), 0o755); err != nil {
		return err
	}
	_ = os.Remove(socketPath)

	listener, err := net.Listen("unix", socketPath)
	if err != nil {
		return err
	}
	defer func() {
		_ = listener.Close()
		_ = os.Remove(socketPath)
	}()

	server := newDaemonServer()
	defer server.closeAll()

	for {
		conn, err := listener.Accept()
		if err != nil {
			if errors.Is(err, net.ErrClosed) {
				return nil
			}
			return err
		}
		go func(conn net.Conn) {
			defer conn.Close()
			_ = rpc.NewServer(server.handleRequest).Serve(conn, conn)
		}(conn)
	}
}

func runTLSServer(cfg direct.Config) error {
	server := newDaemonServer()
	defer server.closeAll()
	cfg.Handler = server.handleRequest
	return direct.NewTLSServer(cfg).Serve(context.Background())
}

func newDaemonServer() *daemonServer {
	return &daemonServer{
		nextStreamID: 1,
		streams:      map[string]net.Conn{},
		sessions:     session.NewManager(),
		terminals:    terminal.NewManager(),
	}
}

func (s *daemonServer) handleRequest(req rpc.Request) rpc.Response {
	if req.Method == "" {
		return rpc.Response{
			ID: req.ID,
			OK: false,
			Error: &rpc.Error{
				Code:    "invalid_request",
				Message: "method is required",
			},
		}
	}

	switch req.Method {
	case "hello":
		return rpc.Response{
			ID: req.ID,
			OK: true,
			Result: map[string]any{
				"name":    "cmuxd-remote",
				"version": version,
				"capabilities": []string{
					"session.basic",
					"session.resize.min",
					"terminal.stream",
					"proxy.http_connect",
					"proxy.socks5",
					"proxy.stream",
				},
			},
		}
	case "ping":
		return rpc.Response{
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
	case "proxy.read":
		return s.handleProxyRead(req)
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
	case "session.list":
		return s.handleSessionList(req)
	case "session.history":
		return s.handleSessionHistory(req)
	case "terminal.open":
		return s.handleTerminalOpen(req)
	case "terminal.read":
		return s.handleTerminalRead(req)
	case "terminal.write":
		return s.handleTerminalWrite(req)
	default:
		return rpc.Response{
			ID: req.ID,
			OK: false,
			Error: &rpc.Error{
				Code:    "method_not_found",
				Message: fmt.Sprintf("unknown method %q", req.Method),
			},
		}
	}
}

func (s *daemonServer) handleProxyOpen(req rpc.Request) rpc.Response {
	host, ok := getStringParam(req.Params, "host")
	if !ok || host == "" {
		return rpc.Response{
			ID: req.ID,
			OK: false,
			Error: &rpc.Error{
				Code:    "invalid_params",
				Message: "proxy.open requires host",
			},
		}
	}
	port, ok := getIntParam(req.Params, "port")
	if !ok || port <= 0 || port > 65535 {
		return rpc.Response{
			ID: req.ID,
			OK: false,
			Error: &rpc.Error{
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
		return rpc.Response{
			ID: req.ID,
			OK: false,
			Error: &rpc.Error{
				Code:    "open_failed",
				Message: err.Error(),
			},
		}
	}

	s.mu.Lock()
	streamID := fmt.Sprintf("s-%d", s.nextStreamID)
	s.nextStreamID++
	s.streams[streamID] = conn
	s.mu.Unlock()

	return rpc.Response{
		ID: req.ID,
		OK: true,
		Result: map[string]any{
			"stream_id": streamID,
		},
	}
}

func (s *daemonServer) handleProxyClose(req rpc.Request) rpc.Response {
	streamID, ok := getStringParam(req.Params, "stream_id")
	if !ok || streamID == "" {
		return rpc.Response{
			ID: req.ID,
			OK: false,
			Error: &rpc.Error{
				Code:    "invalid_params",
				Message: "proxy.close requires stream_id",
			},
		}
	}

	s.mu.Lock()
	conn, exists := s.streams[streamID]
	if exists {
		delete(s.streams, streamID)
	}
	s.mu.Unlock()

	if !exists {
		return rpc.Response{
			ID: req.ID,
			OK: false,
			Error: &rpc.Error{
				Code:    "not_found",
				Message: "stream not found",
			},
		}
	}

	_ = conn.Close()
	return rpc.Response{
		ID: req.ID,
		OK: true,
		Result: map[string]any{
			"closed": true,
		},
	}
}

func (s *daemonServer) handleProxyWrite(req rpc.Request) rpc.Response {
	streamID, ok := getStringParam(req.Params, "stream_id")
	if !ok || streamID == "" {
		return rpc.Response{
			ID: req.ID,
			OK: false,
			Error: &rpc.Error{
				Code:    "invalid_params",
				Message: "proxy.write requires stream_id",
			},
		}
	}
	dataBase64, ok := getStringParam(req.Params, "data_base64")
	if !ok {
		return rpc.Response{
			ID: req.ID,
			OK: false,
			Error: &rpc.Error{
				Code:    "invalid_params",
				Message: "proxy.write requires data_base64",
			},
		}
	}
	payload, err := base64.StdEncoding.DecodeString(dataBase64)
	if err != nil {
		return rpc.Response{
			ID: req.ID,
			OK: false,
			Error: &rpc.Error{
				Code:    "invalid_params",
				Message: "data_base64 must be valid base64",
			},
		}
	}

	conn, found := s.getStream(streamID)
	if !found {
		return rpc.Response{
			ID: req.ID,
			OK: false,
			Error: &rpc.Error{
				Code:    "not_found",
				Message: "stream not found",
			},
		}
	}

	timeoutMs := 8000
	if parsed, hasTimeout := getIntParam(req.Params, "timeout_ms"); hasTimeout {
		timeoutMs = parsed
	}
	if timeoutMs > 0 {
		if err := conn.SetWriteDeadline(time.Now().Add(time.Duration(timeoutMs) * time.Millisecond)); err != nil {
			return rpc.Response{
				ID: req.ID,
				OK: false,
				Error: &rpc.Error{
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
			return rpc.Response{
				ID: req.ID,
				OK: false,
				Error: &rpc.Error{
					Code:    "stream_error",
					Message: "write made no progress",
				},
			}
		}
		total += written
		if writeErr != nil {
			return rpc.Response{
				ID: req.ID,
				OK: false,
				Error: &rpc.Error{
					Code:    "stream_error",
					Message: writeErr.Error(),
				},
			}
		}
	}

	return rpc.Response{
		ID: req.ID,
		OK: true,
		Result: map[string]any{
			"written": total,
		},
	}
}

func (s *daemonServer) handleProxyRead(req rpc.Request) rpc.Response {
	streamID, ok := getStringParam(req.Params, "stream_id")
	if !ok || streamID == "" {
		return rpc.Response{
			ID: req.ID,
			OK: false,
			Error: &rpc.Error{
				Code:    "invalid_params",
				Message: "proxy.read requires stream_id",
			},
		}
	}

	maxBytes := 32768
	if parsed, hasMax := getIntParam(req.Params, "max_bytes"); hasMax {
		maxBytes = parsed
	}
	if maxBytes <= 0 || maxBytes > 262144 {
		return rpc.Response{
			ID: req.ID,
			OK: false,
			Error: &rpc.Error{
				Code:    "invalid_params",
				Message: "max_bytes must be in range 1-262144",
			},
		}
	}

	timeoutMs := 50
	if parsed, hasTimeout := getIntParam(req.Params, "timeout_ms"); hasTimeout && parsed >= 0 {
		timeoutMs = parsed
	}

	conn, found := s.getStream(streamID)
	if !found {
		return rpc.Response{
			ID: req.ID,
			OK: false,
			Error: &rpc.Error{
				Code:    "not_found",
				Message: "stream not found",
			},
		}
	}

	_ = conn.SetReadDeadline(time.Now().Add(time.Duration(timeoutMs) * time.Millisecond))
	buffer := make([]byte, maxBytes)
	n, readErr := conn.Read(buffer)
	data := buffer[:max(0, n)]

	if readErr != nil {
		if netErr, ok := readErr.(net.Error); ok && netErr.Timeout() {
			return rpc.Response{
				ID: req.ID,
				OK: true,
				Result: map[string]any{
					"data_base64": "",
					"eof":         false,
				},
			}
		}
		if readErr == io.EOF {
			s.dropStream(streamID)
			return rpc.Response{
				ID: req.ID,
				OK: true,
				Result: map[string]any{
					"data_base64": base64.StdEncoding.EncodeToString(data),
					"eof":         true,
				},
			}
		}
		return rpc.Response{
			ID: req.ID,
			OK: false,
			Error: &rpc.Error{
				Code:    "stream_error",
				Message: readErr.Error(),
			},
		}
	}

	return rpc.Response{
		ID: req.ID,
		OK: true,
		Result: map[string]any{
			"data_base64": base64.StdEncoding.EncodeToString(data),
			"eof":         false,
		},
	}
}

func (s *daemonServer) handleSessionOpen(req rpc.Request) rpc.Response {
	sessionID, _ := getStringParam(req.Params, "session_id")
	status := s.sessions.Ensure(sessionID)

	return rpc.Response{
		ID:     req.ID,
		OK:     true,
		Result: sessionStatusResult(status),
	}
}

func (s *daemonServer) handleSessionClose(req rpc.Request) rpc.Response {
	sessionID, ok := getStringParam(req.Params, "session_id")
	if !ok || sessionID == "" {
		return rpc.Response{
			ID: req.ID,
			OK: false,
			Error: &rpc.Error{
				Code:    "invalid_params",
				Message: "session.close requires session_id",
			},
		}
	}

	if err := s.sessions.Close(sessionID); err != nil {
		return rpc.Response{
			ID:    req.ID,
			OK:    false,
			Error: sessionError(err),
		}
	}
	if err := s.terminals.Close(sessionID); err != nil && !errors.Is(err, terminal.ErrSessionNotFound) {
		return rpc.Response{
			ID:    req.ID,
			OK:    false,
			Error: terminalError(err),
		}
	}

	return rpc.Response{
		ID: req.ID,
		OK: true,
		Result: map[string]any{
			"session_id": sessionID,
			"closed":     true,
		},
	}
}

func (s *daemonServer) handleSessionAttach(req rpc.Request) rpc.Response {
	sessionID, attachmentID, cols, rows, badResp := parseSessionAttachmentParams(req, "session.attach")
	if badResp != nil {
		return *badResp
	}

	if err := s.sessions.Attach(sessionID, attachmentID, cols, rows); err != nil {
		return rpc.Response{
			ID:    req.ID,
			OK:    false,
			Error: sessionError(err),
		}
	}
	status, err := s.sessions.Status(sessionID)
	if err != nil {
		return rpc.Response{
			ID:    req.ID,
			OK:    false,
			Error: sessionError(err),
		}
	}
	if resizeErr := s.terminals.Resize(sessionID, status.EffectiveCols, status.EffectiveRows); resizeErr != nil &&
		!errors.Is(resizeErr, terminal.ErrSessionNotFound) {
		return rpc.Response{
			ID:    req.ID,
			OK:    false,
			Error: terminalError(resizeErr),
		}
	}

	return rpc.Response{
		ID:     req.ID,
		OK:     true,
		Result: sessionStatusResult(status),
	}
}

func (s *daemonServer) handleSessionResize(req rpc.Request) rpc.Response {
	sessionID, attachmentID, cols, rows, badResp := parseSessionAttachmentParams(req, "session.resize")
	if badResp != nil {
		return *badResp
	}

	if err := s.sessions.Resize(sessionID, attachmentID, cols, rows); err != nil {
		return rpc.Response{
			ID:    req.ID,
			OK:    false,
			Error: sessionError(err),
		}
	}
	status, err := s.sessions.Status(sessionID)
	if err != nil {
		return rpc.Response{
			ID:    req.ID,
			OK:    false,
			Error: sessionError(err),
		}
	}
	if resizeErr := s.terminals.Resize(sessionID, status.EffectiveCols, status.EffectiveRows); resizeErr != nil &&
		!errors.Is(resizeErr, terminal.ErrSessionNotFound) {
		return rpc.Response{
			ID:    req.ID,
			OK:    false,
			Error: terminalError(resizeErr),
		}
	}

	return rpc.Response{
		ID:     req.ID,
		OK:     true,
		Result: sessionStatusResult(status),
	}
}

func (s *daemonServer) handleSessionDetach(req rpc.Request) rpc.Response {
	sessionID, ok := getStringParam(req.Params, "session_id")
	if !ok || sessionID == "" {
		return rpc.Response{
			ID: req.ID,
			OK: false,
			Error: &rpc.Error{
				Code:    "invalid_params",
				Message: "session.detach requires session_id",
			},
		}
	}
	attachmentID, ok := getStringParam(req.Params, "attachment_id")
	if !ok || attachmentID == "" {
		return rpc.Response{
			ID: req.ID,
			OK: false,
			Error: &rpc.Error{
				Code:    "invalid_params",
				Message: "session.detach requires attachment_id",
			},
		}
	}

	if err := s.sessions.Detach(sessionID, attachmentID); err != nil {
		return rpc.Response{
			ID:    req.ID,
			OK:    false,
			Error: sessionError(err),
		}
	}
	status, err := s.sessions.Status(sessionID)
	if err != nil {
		return rpc.Response{
			ID:    req.ID,
			OK:    false,
			Error: sessionError(err),
		}
	}
	if resizeErr := s.terminals.Resize(sessionID, status.EffectiveCols, status.EffectiveRows); resizeErr != nil &&
		!errors.Is(resizeErr, terminal.ErrSessionNotFound) {
		return rpc.Response{
			ID:    req.ID,
			OK:    false,
			Error: terminalError(resizeErr),
		}
	}

	return rpc.Response{
		ID:     req.ID,
		OK:     true,
		Result: sessionStatusResult(status),
	}
}

func (s *daemonServer) handleSessionStatus(req rpc.Request) rpc.Response {
	sessionID, ok := getStringParam(req.Params, "session_id")
	if !ok || sessionID == "" {
		return rpc.Response{
			ID: req.ID,
			OK: false,
			Error: &rpc.Error{
				Code:    "invalid_params",
				Message: "session.status requires session_id",
			},
		}
	}

	status, err := s.sessions.Status(sessionID)
	if err != nil {
		return rpc.Response{
			ID:    req.ID,
			OK:    false,
			Error: sessionError(err),
		}
	}

	return rpc.Response{
		ID:     req.ID,
		OK:     true,
		Result: sessionStatusResult(status),
	}
}

func (s *daemonServer) handleSessionList(req rpc.Request) rpc.Response {
	sessions := s.sessions.List()
	result := make([]map[string]any, 0, len(sessions))
	for _, status := range sessions {
		result = append(result, map[string]any{
			"session_id":       status.SessionID,
			"attachment_count": len(status.Attachments),
			"effective_cols":   status.EffectiveCols,
			"effective_rows":   status.EffectiveRows,
		})
	}
	return rpc.Response{
		ID:     req.ID,
		OK:     true,
		Result: map[string]any{"sessions": result},
	}
}

func (s *daemonServer) handleSessionHistory(req rpc.Request) rpc.Response {
	sessionID, ok := getStringParam(req.Params, "session_id")
	if !ok || sessionID == "" {
		return rpc.Response{
			ID: req.ID,
			OK: false,
			Error: &rpc.Error{
				Code:    "invalid_params",
				Message: "session.history requires session_id",
			},
		}
	}

	history, err := s.terminals.History(sessionID)
	if err != nil {
		return rpc.Response{
			ID:    req.ID,
			OK:    false,
			Error: terminalError(err),
		}
	}
	return rpc.Response{
		ID:     req.ID,
		OK:     true,
		Result: map[string]any{"session_id": sessionID, "history": string(history)},
	}
}

func (s *daemonServer) handleTerminalOpen(req rpc.Request) rpc.Response {
	command, ok := getStringParam(req.Params, "command")
	if !ok || command == "" {
		return rpc.Response{
			ID: req.ID,
			OK: false,
			Error: &rpc.Error{
				Code:    "invalid_params",
				Message: "terminal.open requires command",
			},
		}
	}

	cols, ok := getIntParam(req.Params, "cols")
	if !ok || cols <= 0 {
		return rpc.Response{
			ID: req.ID,
			OK: false,
			Error: &rpc.Error{
				Code:    "invalid_params",
				Message: "terminal.open requires cols > 0",
			},
		}
	}
	rows, ok := getIntParam(req.Params, "rows")
	if !ok || rows <= 0 {
		return rpc.Response{
			ID: req.ID,
			OK: false,
			Error: &rpc.Error{
				Code:    "invalid_params",
				Message: "terminal.open requires rows > 0",
			},
		}
	}

	requestedSessionID, _ := getStringParam(req.Params, "session_id")
	sessionID, attachmentID, err := s.sessions.Open(requestedSessionID, cols, rows)
	if err != nil {
		return rpc.Response{
			ID:    req.ID,
			OK:    false,
			Error: sessionError(err),
		}
	}
	status, err := s.sessions.Status(sessionID)
	if err != nil {
		return rpc.Response{ID: req.ID, OK: false, Error: sessionError(err)}
	}
	if err := s.terminals.Open(sessionID, command, status.EffectiveCols, status.EffectiveRows); err != nil {
		_ = s.sessions.Close(sessionID)
		return rpc.Response{ID: req.ID, OK: false, Error: terminalError(err)}
	}

	result := sessionStatusResult(status)
	result["attachment_id"] = attachmentID
	result["offset"] = 0

	return rpc.Response{
		ID:     req.ID,
		OK:     true,
		Result: result,
	}
}

func (s *daemonServer) handleTerminalRead(req rpc.Request) rpc.Response {
	sessionID, ok := getStringParam(req.Params, "session_id")
	if !ok || sessionID == "" {
		return rpc.Response{
			ID: req.ID,
			OK: false,
			Error: &rpc.Error{
				Code:    "invalid_params",
				Message: "terminal.read requires session_id",
			},
		}
	}

	offset, ok := getUint64Param(req.Params, "offset")
	if !ok {
		return rpc.Response{
			ID: req.ID,
			OK: false,
			Error: &rpc.Error{
				Code:    "invalid_params",
				Message: "terminal.read requires offset >= 0",
			},
		}
	}

	maxBytes := 65536
	if parsed, ok := getIntParam(req.Params, "max_bytes"); ok && parsed > 0 {
		maxBytes = parsed
	}
	timeoutMs := 0
	if parsed, ok := getIntParam(req.Params, "timeout_ms"); ok && parsed >= 0 {
		timeoutMs = parsed
	}

	result, err := s.terminals.Read(sessionID, offset, maxBytes, time.Duration(timeoutMs)*time.Millisecond)
	if err != nil {
		return rpc.Response{ID: req.ID, OK: false, Error: terminalError(err)}
	}

	return rpc.Response{
		ID: req.ID,
		OK: true,
		Result: map[string]any{
			"session_id":  sessionID,
			"offset":      result.Offset,
			"base_offset": result.BaseOffset,
			"truncated":   result.Truncated,
			"eof":         result.EOF,
			"data":        base64.StdEncoding.EncodeToString(result.Data),
		},
	}
}

func (s *daemonServer) handleTerminalWrite(req rpc.Request) rpc.Response {
	sessionID, ok := getStringParam(req.Params, "session_id")
	if !ok || sessionID == "" {
		return rpc.Response{
			ID: req.ID,
			OK: false,
			Error: &rpc.Error{
				Code:    "invalid_params",
				Message: "terminal.write requires session_id",
			},
		}
	}
	encoded, ok := getStringParam(req.Params, "data")
	if !ok {
		return rpc.Response{
			ID: req.ID,
			OK: false,
			Error: &rpc.Error{
				Code:    "invalid_params",
				Message: "terminal.write requires data",
			},
		}
	}
	data, err := base64.StdEncoding.DecodeString(encoded)
	if err != nil {
		return rpc.Response{
			ID: req.ID,
			OK: false,
			Error: &rpc.Error{
				Code:    "invalid_params",
				Message: "terminal.write data must be base64",
			},
		}
	}
	if err := s.terminals.Write(sessionID, data); err != nil {
		return rpc.Response{ID: req.ID, OK: false, Error: terminalError(err)}
	}

	return rpc.Response{
		ID: req.ID,
		OK: true,
		Result: map[string]any{
			"session_id": sessionID,
			"written":    len(data),
		},
	}
}

func parseSessionAttachmentParams(req rpc.Request, method string) (sessionID string, attachmentID string, cols int, rows int, badResp *rpc.Response) {
	sessionID, ok := getStringParam(req.Params, "session_id")
	if !ok || sessionID == "" {
		resp := rpc.Response{
			ID: req.ID,
			OK: false,
			Error: &rpc.Error{
				Code:    "invalid_params",
				Message: method + " requires session_id",
			},
		}
		return "", "", 0, 0, &resp
	}
	attachmentID, ok = getStringParam(req.Params, "attachment_id")
	if !ok || attachmentID == "" {
		resp := rpc.Response{
			ID: req.ID,
			OK: false,
			Error: &rpc.Error{
				Code:    "invalid_params",
				Message: method + " requires attachment_id",
			},
		}
		return "", "", 0, 0, &resp
	}

	cols, ok = getIntParam(req.Params, "cols")
	if !ok || cols <= 0 {
		resp := rpc.Response{
			ID: req.ID,
			OK: false,
			Error: &rpc.Error{
				Code:    "invalid_params",
				Message: method + " requires cols > 0",
			},
		}
		return "", "", 0, 0, &resp
	}
	rows, ok = getIntParam(req.Params, "rows")
	if !ok || rows <= 0 {
		resp := rpc.Response{
			ID: req.ID,
			OK: false,
			Error: &rpc.Error{
				Code:    "invalid_params",
				Message: method + " requires rows > 0",
			},
		}
		return "", "", 0, 0, &resp
	}

	return sessionID, attachmentID, cols, rows, nil
}

func sessionStatusResult(status session.SessionStatus) map[string]any {
	attachments := make([]map[string]any, 0, len(status.Attachments))
	for _, attachment := range status.Attachments {
		attachments = append(attachments, map[string]any{
			"attachment_id": attachment.AttachmentID,
			"cols":          attachment.Cols,
			"rows":          attachment.Rows,
			"updated_at":    attachment.UpdatedAt.Format(time.RFC3339Nano),
		})
	}
	return map[string]any{
		"session_id":      status.SessionID,
		"attachments":     attachments,
		"effective_cols":  status.EffectiveCols,
		"effective_rows":  status.EffectiveRows,
		"last_known_cols": status.LastKnownCols,
		"last_known_rows": status.LastKnownRows,
	}
}

func sessionError(err error) *rpc.Error {
	switch err {
	case nil:
		return nil
	case session.ErrSessionNotFound:
		return &rpc.Error{Code: "not_found", Message: "session not found"}
	case session.ErrSessionExists:
		return &rpc.Error{Code: "already_exists", Message: err.Error()}
	case session.ErrAttachmentNotFound:
		return &rpc.Error{Code: "not_found", Message: "attachment not found"}
	case session.ErrInvalidSize:
		return &rpc.Error{Code: "invalid_params", Message: err.Error()}
	default:
		return &rpc.Error{Code: "internal_error", Message: err.Error()}
	}
}

func terminalError(err error) *rpc.Error {
	switch err {
	case nil:
		return nil
	case terminal.ErrSessionNotFound:
		return &rpc.Error{Code: "not_found", Message: "terminal session not found"}
	case terminal.ErrReadTimeout:
		return &rpc.Error{Code: "deadline_exceeded", Message: err.Error()}
	case terminal.ErrInvalidCommand, terminal.ErrSessionExists:
		return &rpc.Error{Code: "invalid_params", Message: err.Error()}
	default:
		return &rpc.Error{Code: "internal_error", Message: err.Error()}
	}
}

func (s *daemonServer) getStream(streamID string) (net.Conn, bool) {
	s.mu.Lock()
	defer s.mu.Unlock()
	conn, ok := s.streams[streamID]
	return conn, ok
}

func (s *daemonServer) dropStream(streamID string) {
	s.mu.Lock()
	conn, ok := s.streams[streamID]
	if ok {
		delete(s.streams, streamID)
	}
	s.mu.Unlock()
	if ok {
		_ = conn.Close()
	}
}

func (s *daemonServer) closeAll() {
	s.mu.Lock()
	streams := make([]net.Conn, 0, len(s.streams))
	for id, conn := range s.streams {
		delete(s.streams, id)
		streams = append(streams, conn)
	}
	s.mu.Unlock()
	for _, conn := range streams {
		_ = conn.Close()
	}
	s.terminals.CloseAll()
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

func getUint64Param(params map[string]any, key string) (uint64, bool) {
	if params == nil {
		return 0, false
	}
	raw, ok := params[key]
	if !ok || raw == nil {
		return 0, false
	}
	switch value := raw.(type) {
	case uint64:
		return value, true
	case uint:
		return uint64(value), true
	case uint32:
		return uint64(value), true
	case uint16:
		return uint64(value), true
	case uint8:
		return uint64(value), true
	case int:
		if value < 0 {
			return 0, false
		}
		return uint64(value), true
	case int64:
		if value < 0 {
			return 0, false
		}
		return uint64(value), true
	case int32:
		if value < 0 {
			return 0, false
		}
		return uint64(value), true
	case float64:
		if value < 0 {
			return 0, false
		}
		return uint64(value), true
	case json.Number:
		n, err := value.Int64()
		if err != nil || n < 0 {
			return 0, false
		}
		return uint64(n), true
	default:
		return 0, false
	}
}
