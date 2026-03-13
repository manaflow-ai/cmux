package main

import (
	"bufio"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net"
	"os"
	"path/filepath"
	"strings"
	"time"
)

type relayAuthState struct {
	RelayID    string `json:"relay_id"`
	RelayToken string `json:"relay_token"`
}

// protocolVersion indicates whether a command uses the v1 text or v2 JSON-RPC protocol.
type protocolVersion int

const (
	protoV1 protocolVersion = iota
	protoV2
)

// commandSpec describes a single CLI command and how to relay it.
type commandSpec struct {
	name     string          // CLI command name (e.g. "ping", "new-window")
	proto    protocolVersion // v1 text or v2 JSON-RPC
	v1Cmd    string          // v1: literal command string sent over the socket
	v2Method string          // v2: JSON-RPC method name
	// flagKeys lists parameter keys this command accepts.
	// They are extracted from --key flags and added to params.
	flagKeys []string
	// noParams means the command takes no parameters at all.
	noParams bool
}

var commands = []commandSpec{
	// V1 text protocol commands
	{name: "ping", proto: protoV1, v1Cmd: "ping", noParams: true},
	{name: "new-window", proto: protoV1, v1Cmd: "new_window", noParams: true},
	{name: "current-window", proto: protoV1, v1Cmd: "current_window", noParams: true},
	{name: "close-window", proto: protoV1, v1Cmd: "close_window", flagKeys: []string{"window"}},
	{name: "focus-window", proto: protoV1, v1Cmd: "focus_window", flagKeys: []string{"window"}},
	{name: "list-windows", proto: protoV1, v1Cmd: "list_windows", noParams: true},

	// V2 JSON-RPC commands
	{name: "capabilities", proto: protoV2, v2Method: "system.capabilities", noParams: true},
	{name: "list-workspaces", proto: protoV2, v2Method: "workspace.list", noParams: true},
	{name: "new-workspace", proto: protoV2, v2Method: "workspace.create", flagKeys: []string{"command", "working-directory", "name"}},
	{name: "close-workspace", proto: protoV2, v2Method: "workspace.close", flagKeys: []string{"workspace"}},
	{name: "select-workspace", proto: protoV2, v2Method: "workspace.select", flagKeys: []string{"workspace"}},
	{name: "current-workspace", proto: protoV2, v2Method: "workspace.current", noParams: true},
	{name: "list-panels", proto: protoV2, v2Method: "panel.list", flagKeys: []string{"workspace"}},
	{name: "focus-panel", proto: protoV2, v2Method: "panel.focus", flagKeys: []string{"panel", "workspace"}},
	{name: "list-panes", proto: protoV2, v2Method: "pane.list", flagKeys: []string{"workspace"}},
	{name: "list-pane-surfaces", proto: protoV2, v2Method: "pane.surfaces", flagKeys: []string{"pane"}},
	{name: "new-pane", proto: protoV2, v2Method: "pane.create", flagKeys: []string{"workspace"}},
	{name: "new-surface", proto: protoV2, v2Method: "surface.create", flagKeys: []string{"workspace", "pane"}},
	{name: "new-split", proto: protoV2, v2Method: "surface.split", flagKeys: []string{"surface", "direction"}},
	{name: "close-surface", proto: protoV2, v2Method: "surface.close", flagKeys: []string{"surface"}},
	{name: "send", proto: protoV2, v2Method: "surface.send_text", flagKeys: []string{"surface", "text"}},
	{name: "send-key", proto: protoV2, v2Method: "surface.send_key", flagKeys: []string{"surface", "key"}},
	{name: "notify", proto: protoV2, v2Method: "notification.create", flagKeys: []string{"title", "body", "workspace"}},
	{name: "refresh-surfaces", proto: protoV2, v2Method: "surface.refresh", noParams: true},
}

var commandIndex map[string]*commandSpec

func init() {
	commandIndex = make(map[string]*commandSpec, len(commands))
	for i := range commands {
		commandIndex[commands[i].name] = &commands[i]
	}
}

// runCLI is the entry point for the "cli" subcommand (or busybox "cmux" invocation).
func runCLI(args []string) int {
	socketPath := os.Getenv("CMUX_SOCKET_PATH")

	// Parse global flags
	var jsonOutput bool
	var remaining []string
	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--socket":
			if i+1 >= len(args) {
				fmt.Fprintln(os.Stderr, "cmux: --socket requires a path")
				return 2
			}
			socketPath = args[i+1]
			i++
		case "--json":
			jsonOutput = true
		case "--help", "-h":
			cliUsage()
			return 0
		default:
			remaining = append(remaining, args[i:]...)
			goto doneFlags
		}
	}
doneFlags:

	if len(remaining) == 0 {
		cliUsage()
		return 2
	}
	cmdName := remaining[0]
	cmdArgs := remaining[1:]
	if cmdName == "help" {
		cliUsage()
		return 0
	}

	// refreshAddr is set when the address came from socket_addr file (not env/flag),
	// allowing retry loops to pick up updated relay ports.
	var refreshAddr func() string
	if socketPath == "" {
		socketPath = readSocketAddrFile()
		refreshAddr = readSocketAddrFile
	}
	if socketPath == "" {
		fmt.Fprintln(os.Stderr, "cmux: CMUX_SOCKET_PATH not set and --socket not provided")
		return 1
	}

	// Special case: "rpc" passthrough
	if cmdName == "rpc" {
		return runRPC(socketPath, cmdArgs, jsonOutput, refreshAddr)
	}

	// Browser subcommand delegation
	if cmdName == "browser" {
		return runBrowserRelay(socketPath, cmdArgs, jsonOutput, refreshAddr)
	}

	spec, ok := commandIndex[cmdName]
	if !ok {
		fmt.Fprintf(os.Stderr, "cmux: unknown command %q\n", cmdName)
		return 2
	}

	switch spec.proto {
	case protoV1:
		return execV1(socketPath, spec, cmdArgs, refreshAddr)
	case protoV2:
		return execV2(socketPath, spec, cmdArgs, jsonOutput, refreshAddr)
	default:
		fmt.Fprintf(os.Stderr, "cmux: internal error: unknown protocol for %q\n", cmdName)
		return 1
	}
}

// execV1 sends a v1 text command over the socket.
func execV1(socketPath string, spec *commandSpec, args []string, refreshAddr func() string) int {
	cmd := spec.v1Cmd

	if !spec.noParams {
		parsed, err := parseFlags(args, spec.flagKeys)
		if err != nil {
			fmt.Fprintf(os.Stderr, "cmux: %v\n", err)
			return 2
		}
		for _, key := range spec.flagKeys {
			if val, ok := parsed.flags[key]; ok {
				cmd += " " + val
			}
		}
	}

	resp, err := socketRoundTrip(socketPath, cmd, refreshAddr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "cmux: %v\n", err)
		return 1
	}
	fmt.Print(resp)
	if !strings.HasSuffix(resp, "\n") {
		fmt.Println()
	}
	return 0
}

// execV2 sends a v2 JSON-RPC request over the socket.
func execV2(socketPath string, spec *commandSpec, args []string, jsonOutput bool, refreshAddr func() string) int {
	params := make(map[string]any)

	if !spec.noParams {
		parsed, err := parseFlags(args, spec.flagKeys)
		if err != nil {
			fmt.Fprintf(os.Stderr, "cmux: %v\n", err)
			return 2
		}
		// Map flag keys to JSON param keys (e.g. "workspace" → "workspace_id" where appropriate)
		for _, key := range spec.flagKeys {
			if val, ok := parsed.flags[key]; ok {
				paramKey := flagToParamKey(key)
				params[paramKey] = val
			}
		}

		// First positional arg is used as initial_command if --command wasn't given
		if _, ok := params["initial_command"]; !ok && len(parsed.positional) > 0 {
			params["initial_command"] = parsed.positional[0]
		}

		// Fall back to env vars for common IDs
		if _, ok := params["workspace_id"]; !ok {
			if envWs := os.Getenv("CMUX_WORKSPACE_ID"); envWs != "" {
				params["workspace_id"] = envWs
			}
		}
		if _, ok := params["surface_id"]; !ok {
			if envSf := os.Getenv("CMUX_SURFACE_ID"); envSf != "" {
				params["surface_id"] = envSf
			}
		}
	}

	resp, err := socketRoundTripV2(socketPath, spec.v2Method, params, refreshAddr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "cmux: %v\n", err)
		return 1
	}

	if jsonOutput {
		fmt.Println(resp)
	} else {
		fmt.Println(defaultRelayOutput(resp))
	}
	return 0
}

// runRPC sends an arbitrary JSON-RPC method with optional JSON params.
func runRPC(socketPath string, args []string, jsonOutput bool, refreshAddr func() string) int {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "cmux rpc: requires a method name")
		return 2
	}
	method := args[0]
	var params map[string]any
	if len(args) > 1 {
		if err := json.Unmarshal([]byte(args[1]), &params); err != nil {
			fmt.Fprintf(os.Stderr, "cmux rpc: invalid JSON params: %v\n", err)
			return 2
		}
	}

	resp, err := socketRoundTripV2(socketPath, method, params, refreshAddr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "cmux: %v\n", err)
		return 1
	}
	fmt.Println(resp)
	return 0
}

// runBrowserRelay handles "cmux browser <subcommand>" by mapping to browser.* v2 methods.
func runBrowserRelay(socketPath string, args []string, jsonOutput bool, refreshAddr func() string) int {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "cmux browser: requires a subcommand (open, navigate, back, forward, reload, get-url)")
		return 2
	}

	sub := args[0]
	subArgs := args[1:]

	var method string
	var flagKeys []string
	switch sub {
	case "open", "open-split", "new":
		method = "browser.open"
		flagKeys = []string{"url", "workspace", "surface"}
	case "navigate":
		method = "browser.navigate"
		flagKeys = []string{"url", "surface"}
	case "back":
		method = "browser.back"
		flagKeys = []string{"surface"}
	case "forward":
		method = "browser.forward"
		flagKeys = []string{"surface"}
	case "reload":
		method = "browser.reload"
		flagKeys = []string{"surface"}
	case "get-url":
		method = "browser.get_url"
		flagKeys = []string{"surface"}
	default:
		fmt.Fprintf(os.Stderr, "cmux browser: unknown subcommand %q\n", sub)
		return 2
	}

	params := make(map[string]any)
	parsed, err := parseFlags(subArgs, flagKeys)
	if err != nil {
		fmt.Fprintf(os.Stderr, "cmux browser: %v\n", err)
		return 2
	}
	for _, key := range flagKeys {
		if val, ok := parsed.flags[key]; ok {
			paramKey := flagToParamKey(key)
			params[paramKey] = val
		}
	}

	resp, err := socketRoundTripV2(socketPath, method, params, refreshAddr)
	if err != nil {
		fmt.Fprintf(os.Stderr, "cmux: %v\n", err)
		return 1
	}
	if jsonOutput {
		fmt.Println(resp)
	} else {
		fmt.Println(defaultRelayOutput(resp))
	}
	return 0
}

func defaultRelayOutput(resp string) string {
	var result any
	if err := json.Unmarshal([]byte(resp), &result); err != nil {
		trimmed := strings.TrimSpace(resp)
		if trimmed == "" {
			return "OK"
		}
		return trimmed
	}

	if relayResultIsEmpty(result) {
		return "OK"
	}

	switch typed := result.(type) {
	case string:
		return typed
	default:
		encoded, err := json.MarshalIndent(typed, "", "  ")
		if err != nil {
			return "OK"
		}
		return string(encoded)
	}
}

func relayResultIsEmpty(result any) bool {
	switch typed := result.(type) {
	case nil:
		return true
	case map[string]any:
		return len(typed) == 0
	case []any:
		return len(typed) == 0
	case string:
		return typed == ""
	default:
		return false
	}
}

// flagToParamKey maps a CLI flag name to its JSON-RPC param key.
func flagToParamKey(key string) string {
	switch key {
	case "workspace":
		return "workspace_id"
	case "surface":
		return "surface_id"
	case "panel":
		return "panel_id"
	case "pane":
		return "pane_id"
	case "window":
		return "window_id"
	case "command":
		return "initial_command"
	case "name":
		return "title"
	case "working-directory":
		return "working_directory"
	default:
		return key
	}
}

// parsedFlags holds the results of flag parsing.
type parsedFlags struct {
	flags      map[string]string // --key value pairs
	positional []string          // non-flag arguments
}

// parseFlags extracts --key value pairs from args for the given allowed keys.
// Non-flag arguments are collected in positional.
func parseFlags(args []string, keys []string) (parsedFlags, error) {
	allowed := make(map[string]bool, len(keys))
	for _, k := range keys {
		allowed[k] = true
	}

	result := parsedFlags{flags: make(map[string]string)}
	for i := 0; i < len(args); i++ {
		if args[i] == "--" {
			result.positional = append(result.positional, args[i+1:]...)
			break
		}
		if !strings.HasPrefix(args[i], "--") {
			result.positional = append(result.positional, args[i])
			continue
		}
		key := strings.TrimPrefix(args[i], "--")
		if !allowed[key] {
			return parsedFlags{}, fmt.Errorf("unknown flag --%s", key)
		}
		if i+1 < len(args) {
			result.flags[key] = args[i+1]
			i++
		}
	}
	return result, nil
}

// readSocketAddrFile reads the socket address from ~/.cmux/socket_addr as a fallback
// when CMUX_SOCKET_PATH is not set. Written by the cmux app after the relay establishes.
func readSocketAddrFile() string {
	home, err := os.UserHomeDir()
	if err != nil {
		return ""
	}
	data, err := os.ReadFile(filepath.Join(home, ".cmux", "socket_addr"))
	if err != nil {
		return ""
	}
	return strings.TrimSpace(string(data))
}

func readRelayAuthFile(socketPath string) *relayAuthState {
	if strings.Contains(socketPath, ":") && !strings.HasPrefix(socketPath, "/") {
		_, port, err := net.SplitHostPort(socketPath)
		if err != nil || port == "" {
			return nil
		}
		home, err := os.UserHomeDir()
		if err != nil {
			return nil
		}
		data, err := os.ReadFile(filepath.Join(home, ".cmux", "relay", port+".auth"))
		if err != nil {
			return nil
		}
		var state relayAuthState
		if err := json.Unmarshal(data, &state); err != nil {
			return nil
		}
		if state.RelayID == "" || state.RelayToken == "" {
			return nil
		}
		return &state
	}
	return nil
}

func currentRelayAuth(socketPath string) *relayAuthState {
	relayID := strings.TrimSpace(os.Getenv("CMUX_RELAY_ID"))
	relayToken := strings.TrimSpace(os.Getenv("CMUX_RELAY_TOKEN"))
	if relayID != "" && relayToken != "" {
		return &relayAuthState{RelayID: relayID, RelayToken: relayToken}
	}
	return readRelayAuthFile(socketPath)
}

// dialSocket connects to the cmux socket. If addr contains a colon and doesn't
// start with '/', it's treated as a TCP address (host:port); otherwise Unix socket.
// For TCP connections, it retries briefly to allow the SSH reverse forward to establish.
// refreshAddr, if non-nil, is called on each retry to pick up updated socket_addr files.
func dialSocket(addr string, refreshAddr func() string) (net.Conn, error) {
	if strings.Contains(addr, ":") && !strings.HasPrefix(addr, "/") {
		conn, connectedAddr, err := dialTCPRetry(addr, 15*time.Second, refreshAddr)
		if err != nil {
			return nil, err
		}
		if auth := currentRelayAuth(connectedAddr); auth != nil {
			if err := authenticateRelayConn(conn, auth); err != nil {
				conn.Close()
				return nil, err
			}
		}
		return conn, nil
	}
	return net.Dial("unix", addr)
}

// dialTCPRetry attempts a TCP connection, retrying on "connection refused" for up to timeout.
// This handles the case where the SSH reverse relay hasn't finished establishing yet.
// If refreshAddr is non-nil, it's called on each retry to pick up updated addresses
// (e.g. when socket_addr is rewritten by a new relay process).
func dialTCPRetry(addr string, timeout time.Duration, refreshAddr func() string) (net.Conn, string, error) {
	deadline := time.Now().Add(timeout)
	interval := 250 * time.Millisecond
	printed := false
	for {
		conn, err := net.DialTimeout("tcp", addr, 2*time.Second)
		if err == nil {
			setTCPNoDelay(conn)
			return conn, addr, nil
		}
		if time.Now().After(deadline) {
			return nil, addr, err
		}
		// Only retry on connection refused (relay not ready yet)
		if !isConnectionRefused(err) {
			return nil, addr, err
		}
		if !printed {
			fmt.Fprintf(os.Stderr, "cmux: waiting for relay on %s...\n", addr)
			printed = true
		}
		time.Sleep(interval)
		// Re-read socket_addr in case the relay port has changed
		if refreshAddr != nil {
			if newAddr := refreshAddr(); newAddr != "" && newAddr != addr {
				addr = newAddr
				fmt.Fprintf(os.Stderr, "cmux: relay address updated to %s\n", addr)
			}
		}
	}
}

func isConnectionRefused(err error) bool {
	if opErr, ok := err.(*net.OpError); ok {
		return strings.Contains(opErr.Err.Error(), "connection refused")
	}
	return strings.Contains(err.Error(), "connection refused")
}

func authenticateRelayConn(conn net.Conn, auth *relayAuthState) error {
	reader := bufio.NewReader(conn)
	_ = conn.SetDeadline(time.Now().Add(5 * time.Second))

	var challenge struct {
		Protocol string `json:"protocol"`
		Version  int    `json:"version"`
		RelayID  string `json:"relay_id"`
		Nonce    string `json:"nonce"`
	}
	line, err := reader.ReadString('\n')
	if err != nil {
		return fmt.Errorf("failed to read relay auth challenge: %w", err)
	}
	if err := json.Unmarshal([]byte(line), &challenge); err != nil {
		return fmt.Errorf("invalid relay auth challenge")
	}
	if challenge.Protocol != "cmux-relay-auth" || challenge.Version != 1 || challenge.RelayID != auth.RelayID || challenge.Nonce == "" {
		return fmt.Errorf("relay auth challenge mismatch")
	}

	tokenBytes, err := hex.DecodeString(auth.RelayToken)
	if err != nil {
		return fmt.Errorf("invalid relay auth token")
	}
	mac := computeRelayMAC(tokenBytes, auth.RelayID, challenge.Nonce, challenge.Version)
	payload, err := json.Marshal(map[string]any{
		"relay_id": auth.RelayID,
		"mac":      hex.EncodeToString(mac),
	})
	if err != nil {
		return fmt.Errorf("failed to encode relay auth response: %w", err)
	}
	if _, err := conn.Write(append(payload, '\n')); err != nil {
		return fmt.Errorf("failed to send relay auth response: %w", err)
	}

	line, err = reader.ReadString('\n')
	if err != nil {
		return fmt.Errorf("failed to read relay auth result: %w", err)
	}
	var result struct {
		OK bool `json:"ok"`
	}
	if err := json.Unmarshal([]byte(line), &result); err != nil {
		return fmt.Errorf("invalid relay auth result")
	}
	if !result.OK {
		return fmt.Errorf("relay auth rejected")
	}
	_ = conn.SetDeadline(time.Time{})
	return nil
}

func computeRelayMAC(token []byte, relayID, nonce string, version int) []byte {
	mac := hmac.New(sha256.New, token)
	_, _ = io.WriteString(mac, fmt.Sprintf("relay_id=%s\nnonce=%s\nversion=%d", relayID, nonce, version))
	return mac.Sum(nil)
}

// socketRoundTrip sends a raw text line and reads a raw text response (v1).
func socketRoundTrip(socketPath, command string, refreshAddr func() string) (string, error) {
	conn, err := dialSocket(socketPath, refreshAddr)
	if err != nil {
		return "", fmt.Errorf("failed to connect to %s: %w", socketPath, err)
	}
	defer conn.Close()

	if _, err := fmt.Fprintf(conn, "%s\n", command); err != nil {
		return "", fmt.Errorf("failed to send command: %w", err)
	}

	// V1 handlers may return multiple lines (e.g. list_windows). Read until
	// the stream goes idle briefly after seeing at least one newline.
	reader := bufio.NewReader(conn)
	var response strings.Builder
	sawNewline := false

	for {
		readTimeout := 15 * time.Second
		if sawNewline {
			readTimeout = 120 * time.Millisecond
		}
		_ = conn.SetReadDeadline(time.Now().Add(readTimeout))

		chunk, err := reader.ReadString('\n')
		if chunk != "" {
			response.WriteString(chunk)
			if strings.Contains(chunk, "\n") {
				sawNewline = true
			}
		}

		if err != nil {
			if netErr, ok := err.(net.Error); ok && netErr.Timeout() {
				if sawNewline {
					break
				}
				return "", fmt.Errorf("failed to read response: timeout waiting for response")
			}
			if errors.Is(err, io.EOF) {
				break
			}
			return "", fmt.Errorf("failed to read response: %w", err)
		}
	}

	return strings.TrimRight(response.String(), "\n"), nil
}

// socketRoundTripV2 sends a JSON-RPC request and returns the result JSON.
func socketRoundTripV2(socketPath, method string, params map[string]any, refreshAddr func() string) (string, error) {
	conn, err := dialSocket(socketPath, refreshAddr)
	if err != nil {
		return "", fmt.Errorf("failed to connect to %s: %w", socketPath, err)
	}
	defer conn.Close()

	id := randomHex(8)
	req := map[string]any{
		"id":     id,
		"method": method,
	}
	if params != nil {
		req["params"] = params
	} else {
		req["params"] = map[string]any{}
	}

	payload, err := json.Marshal(req)
	if err != nil {
		return "", fmt.Errorf("failed to marshal request: %w", err)
	}

	if _, err := conn.Write(append(payload, '\n')); err != nil {
		return "", fmt.Errorf("failed to send request: %w", err)
	}

	reader := bufio.NewReader(conn)
	line, err := reader.ReadString('\n')
	if err != nil {
		return "", fmt.Errorf("failed to read response: %w", err)
	}

	// Parse the response to check for errors
	var resp map[string]any
	if err := json.Unmarshal([]byte(line), &resp); err != nil {
		return strings.TrimRight(line, "\n"), nil
	}

	if ok, _ := resp["ok"].(bool); !ok {
		if errObj, _ := resp["error"].(map[string]any); errObj != nil {
			code, _ := errObj["code"].(string)
			msg, _ := errObj["message"].(string)
			return "", fmt.Errorf("server error [%s]: %s", code, msg)
		}
		return "", fmt.Errorf("server returned error response")
	}

	// Return the result portion as JSON
	if result, ok := resp["result"]; ok {
		resultJSON, err := json.Marshal(result)
		if err != nil {
			return "", fmt.Errorf("failed to marshal result: %w", err)
		}
		return string(resultJSON), nil
	}

	return "{}", nil
}

func randomHex(n int) string {
	b := make([]byte, n)
	_, _ = rand.Read(b)
	return hex.EncodeToString(b)
}

func cliUsage() {
	fmt.Fprintln(os.Stderr, "Usage: cmux [--socket <path>] [--json] <command> [args...]")
	fmt.Fprintln(os.Stderr, "")
	fmt.Fprintln(os.Stderr, "Commands:")
	fmt.Fprintln(os.Stderr, "  ping                     Check connectivity")
	fmt.Fprintln(os.Stderr, "  capabilities              List server capabilities")
	fmt.Fprintln(os.Stderr, "  list-workspaces           List all workspaces")
	fmt.Fprintln(os.Stderr, "  new-window                Create a new window")
	fmt.Fprintln(os.Stderr, "  new-workspace             Create a new workspace")
	fmt.Fprintln(os.Stderr, "  new-surface               Create a new surface")
	fmt.Fprintln(os.Stderr, "  new-split                 Split an existing surface")
	fmt.Fprintln(os.Stderr, "  close-surface             Close a surface")
	fmt.Fprintln(os.Stderr, "  close-workspace           Close a workspace")
	fmt.Fprintln(os.Stderr, "  select-workspace          Select a workspace")
	fmt.Fprintln(os.Stderr, "  send                      Send text to a surface")
	fmt.Fprintln(os.Stderr, "  send-key                  Send a key to a surface")
	fmt.Fprintln(os.Stderr, "  notify                    Create a notification")
	fmt.Fprintln(os.Stderr, "  browser <sub>             Browser commands (open, navigate, back, forward, reload, get-url)")
	fmt.Fprintln(os.Stderr, "  rpc <method> [json-params] Send arbitrary JSON-RPC")
}
