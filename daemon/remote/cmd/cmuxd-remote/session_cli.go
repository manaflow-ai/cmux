package main

import (
	"bytes"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/signal"
	"strings"
	"sync/atomic"
	"syscall"
	"time"
	"unsafe"
)

func runSessionCLI(args []string) int {
	socketPath, filtered, err := resolveSessionSocket(args)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	if len(filtered) == 0 {
		sessionUsage()
		return 2
	}

	switch filtered[0] {
	case "ls", "list":
		return sessionList(socketPath)
	case "status":
		if len(filtered) < 2 {
			fmt.Fprintln(os.Stderr, "status requires a session id")
			return 2
		}
		return sessionStatus(socketPath, filtered[1])
	case "history":
		if len(filtered) < 2 {
			fmt.Fprintln(os.Stderr, "history requires a session id")
			return 2
		}
		return sessionHistory(socketPath, filtered[1])
	case "kill":
		if len(filtered) < 2 {
			fmt.Fprintln(os.Stderr, "kill requires a session id")
			return 2
		}
		return sessionKill(socketPath, filtered[1])
	case "new":
		return sessionNew(socketPath, filtered[1:])
	case "attach":
		if len(filtered) < 2 {
			fmt.Fprintln(os.Stderr, "attach requires a session id")
			return 2
		}
		return sessionAttach(socketPath, filtered[1])
	default:
		sessionUsage()
		return 2
	}
}

func resolveSessionSocket(args []string) (string, []string, error) {
	socketPath := findSocketArg(args)
	filtered := stripSocketArg(args)
	if socketPath == "" {
		socketPath = strings.TrimSpace(os.Getenv("CMUXD_UNIX_PATH"))
	}
	if socketPath == "" {
		socketPath = strings.TrimSpace(os.Getenv("CMUX_SOCKET_PATH"))
	}
	if socketPath == "" {
		return "", nil, errors.New("missing --socket and CMUXD_UNIX_PATH")
	}
	return socketPath, filtered, nil
}

func findSocketArg(args []string) string {
	for i := 0; i < len(args); i++ {
		if args[i] == "--socket" && i+1 < len(args) {
			return args[i+1]
		}
	}
	return ""
}

func stripSocketArg(args []string) []string {
	out := make([]string, 0, len(args))
	for i := 0; i < len(args); i++ {
		if args[i] == "--socket" && i+1 < len(args) {
			i++
			continue
		}
		out = append(out, args[i])
	}
	return out
}

func sessionList(socketPath string) int {
	result, err := callJSONRPCValue(socketPath, "session.list", map[string]any{})
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	value, ok := result.(map[string]any)
	if !ok {
		fmt.Fprintln(os.Stderr, "session.list returned an invalid response")
		return 1
	}
	sessions, _ := value["sessions"].([]any)
	if len(sessions) == 0 {
		fmt.Println("No sessions")
		return 0
	}

	for _, item := range sessions {
		session, _ := item.(map[string]any)
		sessionID := stringField(session["session_id"])
		statusResult, err := callJSONRPCValue(socketPath, "session.status", map[string]any{
			"session_id": sessionID,
		})
		if err != nil {
			fmt.Fprintln(os.Stderr, err)
			return 1
		}
		status, ok := statusResult.(map[string]any)
		if !ok {
			fmt.Fprintln(os.Stderr, "session.status returned an invalid response")
			return 1
		}

		effectiveCols := intField(status["effective_cols"])
		effectiveRows := intField(status["effective_rows"])
		attachments, _ := status["attachments"].([]any)
		if len(attachments) == 0 {
			fmt.Printf("session %s %dx%d [detached]\n", sessionID, effectiveCols, effectiveRows)
			continue
		}

		fmt.Printf(
			"session %s %dx%d attachments=%d\n",
			sessionID,
			effectiveCols,
			effectiveRows,
			len(attachments),
		)
		for i, rawAttachment := range attachments {
			attachment, _ := rawAttachment.(map[string]any)
			branch := "├──"
			if i+1 == len(attachments) {
				branch = "└──"
			}
			fmt.Printf(
				"%s %s %dx%d\n",
				branch,
				stringField(attachment["attachment_id"]),
				intField(attachment["cols"]),
				intField(attachment["rows"]),
			)
		}
	}
	return 0
}

func sessionStatus(socketPath, sessionID string) int {
	result, err := callJSONRPCValue(socketPath, "session.status", map[string]any{
		"session_id": sessionID,
	})
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	status, ok := result.(map[string]any)
	if !ok {
		fmt.Fprintln(os.Stderr, "session.status returned an invalid response")
		return 1
	}
	fmt.Printf("%s %dx%d\n", sessionID, intField(status["effective_cols"]), intField(status["effective_rows"]))
	return 0
}

func sessionHistory(socketPath, sessionID string) int {
	result, err := callJSONRPCValue(socketPath, "session.history", map[string]any{
		"session_id": sessionID,
	})
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	value, ok := result.(map[string]any)
	if !ok {
		fmt.Fprintln(os.Stderr, "session.history returned an invalid response")
		return 1
	}
	fmt.Print(stringField(value["history"]))
	return 0
}

func sessionKill(socketPath, sessionID string) int {
	if _, err := callJSONRPCValue(socketPath, "session.close", map[string]any{
		"session_id": sessionID,
	}); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	fmt.Println(sessionID)
	return 0
}

func sessionNew(socketPath string, args []string) int {
	if len(args) == 0 {
		fmt.Fprintln(os.Stderr, "new requires a session id")
		return 2
	}
	sessionID := args[0]
	var detached bool
	var quiet bool
	command := "exec ${SHELL:-/bin/sh} -l"
	for i := 1; i < len(args); i++ {
		switch args[i] {
		case "--detached":
			detached = true
		case "--quiet":
			quiet = true
		case "--":
			if i+1 < len(args) {
				command = strings.Join(args[i+1:], " ")
			}
			i = len(args)
		default:
			fmt.Fprintf(os.Stderr, "unknown flag %s\n", args[i])
			return 2
		}
	}

	cols, rows := currentTerminalSize()
	result, err := callJSONRPCValue(socketPath, "terminal.open", map[string]any{
		"session_id": sessionID,
		"command":    command,
		"cols":       cols,
		"rows":       rows,
	})
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	value, ok := result.(map[string]any)
	if !ok {
		fmt.Fprintln(os.Stderr, "terminal.open returned an invalid response")
		return 1
	}
	attachmentID := stringField(value["attachment_id"])
	if attachmentID == "" {
		fmt.Fprintln(os.Stderr, "terminal.open did not return attachment_id")
		return 1
	}
	if !quiet {
		fmt.Println(sessionID)
	}
	if _, err := callJSONRPCValue(socketPath, "session.detach", map[string]any{
		"session_id":    sessionID,
		"attachment_id": attachmentID,
	}); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	if detached {
		return 0
	}
	return sessionAttach(socketPath, sessionID)
}

func sessionAttach(socketPath, sessionID string) int {
	attachmentID := fmt.Sprintf("cli-%d-%d", os.Getpid(), time.Now().Unix())
	cols, rows := currentTerminalSize()
	if _, err := callJSONRPCValue(socketPath, "session.attach", map[string]any{
		"session_id":    sessionID,
		"attachment_id": attachmentID,
		"cols":          cols,
		"rows":          rows,
	}); err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	attached := true
	defer func() {
		if !attached {
			return
		}
		_, _ = callJSONRPCValue(socketPath, "session.detach", map[string]any{
			"session_id":    sessionID,
			"attachment_id": attachmentID,
		})
	}()

	fd := int(os.Stdin.Fd())
	oldState, err := makeRaw(fd)
	if err != nil {
		fmt.Fprintln(os.Stderr, err)
		return 1
	}
	defer func() {
		_ = restoreTerminal(fd, oldState)
	}()

	var stop atomic.Bool
	done := make(chan struct{})

	winch := make(chan os.Signal, 1)
	signal.Notify(winch, syscall.SIGWINCH)
	defer signal.Stop(winch)

	go func() {
		for {
			select {
			case <-done:
				return
			case <-winch:
				if stop.Load() {
					return
				}
				cols, rows := currentTerminalSize()
				_, _ = callJSONRPCValue(socketPath, "session.resize", map[string]any{
					"session_id":    sessionID,
					"attachment_id": attachmentID,
					"cols":          cols,
					"rows":          rows,
				})
			}
		}
	}()

	go func() {
		defer close(done)
		var offset uint64
		for !stop.Load() {
			result, err := callJSONRPCValue(socketPath, "terminal.read", map[string]any{
				"session_id": sessionID,
				"offset":     offset,
				"max_bytes":  32 * 1024,
				"timeout_ms": 200,
			})
			if err != nil {
				if strings.Contains(err.Error(), "deadline_exceeded") || strings.Contains(err.Error(), "terminal read timed out") {
					continue
				}
				return
			}
			value, ok := result.(map[string]any)
			if !ok {
				return
			}
			offset = uint64(intField(value["offset"]))
			data, err := base64.StdEncoding.DecodeString(stringField(value["data"]))
			if err == nil && len(data) > 0 {
				_, _ = os.Stdout.Write(data)
			}
			if boolField(value["eof"]) {
				return
			}
		}
	}()

	buf := make([]byte, 1024)
	for {
		n, readErr := os.Stdin.Read(buf)
		if n > 0 {
			if bytes.IndexByte(buf[:n], 0x1c) >= 0 {
				break
			}
			if _, err := callJSONRPCValue(socketPath, "terminal.write", map[string]any{
				"session_id": sessionID,
				"data":       base64.StdEncoding.EncodeToString(buf[:n]),
			}); err != nil {
				fmt.Fprintln(os.Stderr, err)
				stop.Store(true)
				<-done
				return 1
			}
		}
		if errors.Is(readErr, io.EOF) {
			break
		}
		if readErr != nil {
			fmt.Fprintln(os.Stderr, readErr)
			stop.Store(true)
			<-done
			return 1
		}
	}

	stop.Store(true)
	_, _ = callJSONRPCValue(socketPath, "session.detach", map[string]any{
		"session_id":    sessionID,
		"attachment_id": attachmentID,
	})
	attached = false
	<-done
	return 0
}

func callJSONRPCValue(socketPath, method string, params map[string]any) (any, error) {
	payload, err := socketRoundTripV2(socketPath, method, params, nil)
	if err != nil {
		return nil, err
	}
	var value any
	if err := json.Unmarshal([]byte(payload), &value); err != nil {
		return nil, err
	}
	return value, nil
}

func currentTerminalSize() (int, int) {
	var ws winsize
	if err := ioctlWinsize(int(os.Stdin.Fd()), syscall.TIOCGWINSZ, &ws); err != nil {
		return 80, 24
	}
	width, height := int(ws.Col), int(ws.Row)
	if width < 2 {
		width = 2
	}
	if height < 1 {
		height = 1
	}
	return width, height
}

func intField(value any) int {
	switch typed := value.(type) {
	case float64:
		return int(typed)
	case int:
		return typed
	default:
		return 0
	}
}

func stringField(value any) string {
	typed, _ := value.(string)
	return typed
}

func boolField(value any) bool {
	typed, _ := value.(bool)
	return typed
}

type terminalState struct {
	termios syscall.Termios
}

type winsize struct {
	Row    uint16
	Col    uint16
	Xpixel uint16
	Ypixel uint16
}

func makeRaw(fd int) (*terminalState, error) {
	var termios syscall.Termios
	if err := ioctlTermios(fd, ioctlReadTermiosRequest(), &termios); err != nil {
		return nil, err
	}
	raw := termios
	raw.Iflag &^= syscall.IGNBRK | syscall.BRKINT | syscall.PARMRK | syscall.ISTRIP | syscall.INLCR | syscall.IGNCR | syscall.ICRNL | syscall.IXON
	raw.Oflag &^= syscall.OPOST
	raw.Lflag &^= syscall.ECHO | syscall.ECHONL | syscall.ICANON | syscall.ISIG | syscall.IEXTEN
	raw.Cflag &^= syscall.CSIZE | syscall.PARENB
	raw.Cflag |= syscall.CS8
	raw.Cc[syscall.VMIN] = 1
	raw.Cc[syscall.VTIME] = 0
	if err := ioctlTermios(fd, ioctlWriteTermiosRequest(), &raw); err != nil {
		return nil, err
	}
	return &terminalState{termios: termios}, nil
}

func restoreTerminal(fd int, state *terminalState) error {
	if state == nil {
		return nil
	}
	return ioctlTermios(fd, ioctlWriteTermiosRequest(), &state.termios)
}

func ioctlTermios(fd int, request uintptr, value *syscall.Termios) error {
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), request, uintptr(unsafe.Pointer(value)))
	if errno != 0 {
		return errno
	}
	return nil
}

func ioctlWinsize(fd int, request uintptr, value *winsize) error {
	_, _, errno := syscall.Syscall(syscall.SYS_IOCTL, uintptr(fd), request, uintptr(unsafe.Pointer(value)))
	if errno != 0 {
		return errno
	}
	return nil
}

func sessionUsage() {
	fmt.Fprintln(os.Stderr, "Usage:")
	fmt.Fprintln(os.Stderr, "  cmuxd-remote session ls|list [--socket <path>]")
	fmt.Fprintln(os.Stderr, "  cmuxd-remote session attach|status|history|kill <name> [--socket <path>]")
	fmt.Fprintln(os.Stderr, "  cmuxd-remote session new <name> [--socket <path>] [--detached] [--quiet] [-- <command>]")
	fmt.Fprintln(os.Stderr, "Defaults:")
	fmt.Fprintln(os.Stderr, "  --socket defaults to $CMUXD_UNIX_PATH when set.")
}
