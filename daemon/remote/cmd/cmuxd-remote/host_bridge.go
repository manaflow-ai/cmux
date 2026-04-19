package main

// host_bridge.go implements a transparent terminal bridge between the local
// terminal's PTY and a remote cmux surface. When run as `cmuxd-remote attach-bridge`,
// it makes the current terminal act as if directly connected to the remote surface.
//
// This is the core of `cmux attach` — the local Ghostty surface runs SSH,
// which runs this bridge, which connects to the host cmux socket, creating
// a seamless terminal proxy chain:
//
//   User ↔ Local Ghostty PTY ↔ SSH ↔ attach-bridge ↔ Host cmux socket ↔ Remote surface

import (
	"bufio"
	"encoding/base64"
	"encoding/json"
	"fmt"
	"net"
	"os"
	"os/signal"
	"strings"
	"sync"
	"syscall"
	"time"
	"unsafe"
)

// runAttachBridge is the entry point for `cmuxd-remote attach-bridge --surface <ref>`.
func runAttachBridge(args []string) int {
	var surfaceRef string
	var readOnly bool
	var pollMs int = 150
	var useVT bool = true

	for i := 0; i < len(args); i++ {
		switch args[i] {
		case "--surface":
			if i+1 < len(args) {
				surfaceRef = args[i+1]
				i++
			}
		case "--read-only":
			readOnly = true
		case "--poll-ms":
			if i+1 < len(args) {
				fmt.Sscanf(args[i+1], "%d", &pollMs)
				i++
			}
		case "--no-vt":
			useVT = false
		}
	}

	if surfaceRef == "" {
		fmt.Fprintln(os.Stderr, "attach-bridge: --surface is required")
		return 2
	}
	if pollMs < 50 {
		pollMs = 50
	}

	bridge := &attachBridge{
		surfaceRef: surfaceRef,
		readOnly:   readOnly,
		pollMs:     pollMs,
		useVT:      useVT,
		stopCh:     make(chan struct{}),
	}

	return bridge.run()
}

type attachBridge struct {
	surfaceRef string
	readOnly   bool
	pollMs     int
	useVT      bool
	stopCh     chan struct{}

	mu          sync.Mutex
	lastScreen  string
	origTermios syscall.Termios
	rawMode     bool
}

func (b *attachBridge) run() int {
	// Connect to host cmux socket
	socketPath := discoverHostSocketPath()
	if socketPath == "" {
		fmt.Fprintln(os.Stderr, "attach-bridge: cannot find host cmux socket")
		return 1
	}

	// Verify surface exists
	result, err := hostCmuxRoundTrip("surface.read_text", map[string]any{
		"surface_id": b.surfaceRef,
	})
	if err != nil {
		fmt.Fprintf(os.Stderr, "attach-bridge: cannot access surface %s: %v\n", b.surfaceRef, err)
		return 1
	}
	_ = result

	// Set terminal to raw mode for input forwarding
	if !b.readOnly {
		if err := b.enableRawMode(); err != nil {
			fmt.Fprintf(os.Stderr, "attach-bridge: failed to set raw mode: %v\n", err)
			// Continue in cooked mode
		}
		defer b.restoreTerminal()
	}

	// Handle SIGWINCH for terminal resize
	sigCh := make(chan os.Signal, 1)
	signal.Notify(sigCh, syscall.SIGWINCH, syscall.SIGINT, syscall.SIGTERM)

	// Start output pump (screen reader)
	go b.outputPump()

	// Start input pump (keyboard reader)
	if !b.readOnly {
		go b.inputPump()
	}

	// Wait for signal
	for {
		select {
		case sig := <-sigCh:
			switch sig {
			case syscall.SIGWINCH:
				// Forward resize to remote surface
				b.handleResize()
			case syscall.SIGINT:
				// Forward Ctrl+C to remote surface
				_, _ = hostCmuxRoundTrip("surface.send_key", map[string]any{
					"surface_id": b.surfaceRef,
					"key":        "ctrl+c",
				})
			case syscall.SIGTERM:
				close(b.stopCh)
				return 0
			}
		case <-b.stopCh:
			return 0
		}
	}
}

// outputPump continuously reads the remote surface's screen and writes it to stdout.
func (b *attachBridge) outputPump() {
	ticker := time.NewTicker(time.Duration(b.pollMs) * time.Millisecond)
	defer ticker.Stop()

	for {
		select {
		case <-b.stopCh:
			return
		case <-ticker.C:
			b.refreshScreen()
		}
	}
}

// refreshScreen reads the remote surface and redraws the local terminal.
func (b *attachBridge) refreshScreen() {
	var screen string

	if b.useVT {
		// Try VT mode first (includes ANSI escape codes)
		result, err := hostCmuxRoundTrip("surface.read_vt", map[string]any{
			"surface_id": b.surfaceRef,
		})
		if err == nil {
			if text, ok := result["text"].(string); ok {
				screen = text
			}
		}
	}

	if screen == "" {
		// Fallback to plain text
		result, err := hostCmuxRoundTrip("surface.read_text", map[string]any{
			"surface_id": b.surfaceRef,
		})
		if err != nil {
			return
		}
		if text, ok := result["text"].(string); ok {
			screen = text
		}
	}

	b.mu.Lock()
	changed := screen != b.lastScreen
	b.lastScreen = screen
	b.mu.Unlock()

	if !changed {
		return
	}

	// Clear screen and redraw
	// ESC[2J = clear screen, ESC[H = cursor home
	os.Stdout.WriteString("\033[2J\033[H")
	os.Stdout.WriteString(screen)
	os.Stdout.Sync()
}

// inputPump reads raw keyboard input and forwards it to the remote surface.
func (b *attachBridge) inputPump() {
	reader := bufio.NewReader(os.Stdin)
	buf := make([]byte, 256)

	for {
		select {
		case <-b.stopCh:
			return
		default:
		}

		n, err := reader.Read(buf)
		if err != nil {
			return
		}
		if n == 0 {
			continue
		}

		input := buf[:n]

		// Check for detach sequence: Ctrl+\ (0x1c)
		if n == 1 && input[0] == 0x1c {
			close(b.stopCh)
			return
		}

		// Translate raw bytes to cmux key events or text
		b.forwardInput(input)
	}
}

// forwardInput sends raw terminal input bytes to the remote cmux surface.
func (b *attachBridge) forwardInput(data []byte) {
	// Handle special key sequences
	if len(data) == 1 {
		switch data[0] {
		case 0x0d: // Enter
			hostCmuxRoundTrip("surface.send_key", map[string]any{
				"surface_id": b.surfaceRef,
				"key":        "Enter",
			})
			return
		case 0x09: // Tab
			hostCmuxRoundTrip("surface.send_key", map[string]any{
				"surface_id": b.surfaceRef,
				"key":        "Tab",
			})
			return
		case 0x7f: // Backspace
			hostCmuxRoundTrip("surface.send_key", map[string]any{
				"surface_id": b.surfaceRef,
				"key":        "Backspace",
			})
			return
		case 0x1b: // Escape
			hostCmuxRoundTrip("surface.send_key", map[string]any{
				"surface_id": b.surfaceRef,
				"key":        "Escape",
			})
			return
		case 0x03: // Ctrl+C
			hostCmuxRoundTrip("surface.send_key", map[string]any{
				"surface_id": b.surfaceRef,
				"key":        "ctrl+c",
			})
			return
		case 0x04: // Ctrl+D
			hostCmuxRoundTrip("surface.send_key", map[string]any{
				"surface_id": b.surfaceRef,
				"key":        "ctrl+d",
			})
			return
		}
	}

	// Handle arrow keys and other escape sequences
	if len(data) == 3 && data[0] == 0x1b && data[1] == 0x5b {
		var key string
		switch data[2] {
		case 'A':
			key = "Up"
		case 'B':
			key = "Down"
		case 'C':
			key = "Right"
		case 'D':
			key = "Left"
		}
		if key != "" {
			hostCmuxRoundTrip("surface.send_key", map[string]any{
				"surface_id": b.surfaceRef,
				"key":        key,
			})
			return
		}
	}

	// Default: send as text
	text := string(data)
	hostCmuxRoundTrip("surface.send_text", map[string]any{
		"surface_id": b.surfaceRef,
		"text":       text,
	})
}

// handleResize reads the current terminal size and notifies the remote surface.
func (b *attachBridge) handleResize() {
	cols, rows := getTerminalSize()
	if cols > 0 && rows > 0 {
		// TODO: cmux doesn't have a surface.resize RPC yet.
		// When it does, we can forward the resize here.
		_ = cols
		_ = rows
	}
}

// enableRawMode puts the terminal into raw mode for direct keystroke capture.
func (b *attachBridge) enableRawMode() error {
	fd := int(os.Stdin.Fd())
	var termios syscall.Termios
	if err := ioctl(fd, syscall.TIOCGETA, uintptr(unsafe.Pointer(&termios))); err != nil {
		return err
	}
	b.origTermios = termios

	// Set raw mode: disable echo, canonical mode, signals, etc.
	termios.Iflag &^= syscall.IGNBRK | syscall.BRKINT | syscall.PARMRK | syscall.ISTRIP | syscall.INLCR | syscall.IGNCR | syscall.ICRNL | syscall.IXON
	termios.Oflag &^= syscall.OPOST
	termios.Lflag &^= syscall.ECHO | syscall.ECHONL | syscall.ICANON | syscall.ISIG | syscall.IEXTEN
	termios.Cflag &^= syscall.CSIZE | syscall.PARENB
	termios.Cflag |= syscall.CS8
	termios.Cc[syscall.VMIN] = 1
	termios.Cc[syscall.VTIME] = 0

	if err := ioctl(fd, syscall.TIOCSETA, uintptr(unsafe.Pointer(&termios))); err != nil {
		return err
	}
	b.rawMode = true
	return nil
}

// restoreTerminal restores the terminal to its original mode.
func (b *attachBridge) restoreTerminal() {
	if !b.rawMode {
		return
	}
	fd := int(os.Stdin.Fd())
	_ = ioctl(fd, syscall.TIOCSETA, uintptr(unsafe.Pointer(&b.origTermios)))
	// Clear screen and show cursor
	os.Stdout.WriteString("\033[2J\033[H\033[?25h")
	os.Stdout.Sync()
}

// getTerminalSize returns the current terminal dimensions.
func getTerminalSize() (cols, rows int) {
	var ws struct {
		Row    uint16
		Col    uint16
		Xpixel uint16
		Ypixel uint16
	}
	fd := int(os.Stdout.Fd())
	if err := ioctl(fd, syscall.TIOCGWINSZ, uintptr(unsafe.Pointer(&ws))); err != nil {
		return 0, 0
	}
	return int(ws.Col), int(ws.Row)
}

// ioctl wrapper for terminal control.
func ioctl(fd int, request uint64, argp uintptr) error {
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), uintptr(request), argp)
	if errno != 0 {
		return errno
	}
	return nil
}

// hostCmuxRoundTripRaw sends a V2 JSON-RPC request to the host cmux socket
// and returns the raw JSON response. Used by the bridge for efficient polling.
func hostCmuxRoundTripRaw(method string, params map[string]any) (string, error) {
	conn, err := dialHostCmux()
	if err != nil {
		return "", err
	}
	defer conn.Close()

	id := randomHex(8)
	req := map[string]any{
		"id":     id,
		"method": method,
		"params": params,
	}
	payload, err := json.Marshal(req)
	if err != nil {
		return "", err
	}

	_ = conn.SetWriteDeadline(time.Now().Add(5 * time.Second))
	if _, err := conn.Write(append(payload, '\n')); err != nil {
		return "", err
	}

	_ = conn.SetReadDeadline(time.Now().Add(15 * time.Second))
	reader := bufio.NewReader(conn)
	line, err := reader.ReadString('\n')
	if err != nil {
		return "", err
	}

	return strings.TrimRight(line, "\n"), nil
}

// dialHostCmuxPersistent creates a persistent connection to the host cmux socket.
// Used for streaming scenarios where creating a new connection per request is too expensive.
func dialHostCmuxPersistent() (net.Conn, *bufio.Reader, error) {
	conn, err := dialHostCmux()
	if err != nil {
		return nil, nil, err
	}
	return conn, bufio.NewReader(conn), nil
}

// VT response helpers
func decodeVTResponse(raw string) (text string, isVT bool, err error) {
	var resp map[string]any
	if err := json.Unmarshal([]byte(raw), &resp); err != nil {
		return "", false, err
	}

	ok, _ := resp["ok"].(bool)
	if !ok {
		if errObj, _ := resp["error"].(map[string]any); errObj != nil {
			msg, _ := errObj["message"].(string)
			return "", false, fmt.Errorf("host cmux error: %s", msg)
		}
		return "", false, fmt.Errorf("host cmux returned error")
	}

	result, _ := resp["result"].(map[string]any)
	if result == nil {
		return "", false, nil
	}

	// Check if base64 is available (more reliable for VT data with special chars)
	if b64, ok := result["base64"].(string); ok && b64 != "" {
		decoded, err := base64.StdEncoding.DecodeString(b64)
		if err == nil {
			vt, _ := result["vt"].(bool)
			return string(decoded), vt, nil
		}
	}

	text, _ = result["text"].(string)
	vt, _ := result["vt"].(bool)
	return text, vt, nil
}
