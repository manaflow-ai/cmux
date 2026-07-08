package cmux

import (
	"bufio"
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"sync"
	"sync/atomic"
	"time"
)

var (
	ErrCommand          = errors.New("cmux mux command error")
	ErrConnection       = errors.New("cmux mux connection error")
	ErrTimeout          = errors.New("cmux mux timeout")
	ErrProtocolMismatch = errors.New("cmux mux protocol mismatch")
	ErrDecode           = errors.New("cmux mux decode error")
)

type CommandError struct {
	Message string
	ID      any
}

func (e *CommandError) Error() string { return e.Message }
func (e *CommandError) Is(target error) bool {
	return target == ErrCommand
}

type connectionError struct{ msg string }

func (e *connectionError) Error() string { return e.msg }
func (e *connectionError) Is(target error) bool {
	return target == ErrConnection
}

type timeoutError struct{ msg string }

func (e *timeoutError) Error() string { return e.msg }
func (e *timeoutError) Is(target error) bool {
	return target == ErrTimeout
}

type protocolError struct{ msg string }

func (e *protocolError) Error() string { return e.msg }
func (e *protocolError) Is(target error) bool {
	return target == ErrProtocolMismatch
}

type decodeError struct{ msg string }

func (e *decodeError) Error() string { return e.msg }
func (e *decodeError) Is(target error) bool {
	return target == ErrDecode
}

type Client struct {
	socketPath            string
	timeout               time.Duration
	allowProtocolV6Attach bool
	conn                  *jsonLineConn
	mu                    sync.Mutex
	nextID                atomic.Uint64
	protocol              *uint32
}

type Options struct {
	SocketPath            string
	Session               string
	Timeout               time.Duration
	AllowProtocolV6Attach bool
}

func NewClient(options Options) (*Client, error) {
	session := options.Session
	if session == "" {
		session = "main"
	}
	socketPath := options.SocketPath
	if socketPath == "" {
		socketPath = DefaultSocketPath(session)
	}
	timeout := options.Timeout
	if timeout == 0 {
		timeout = 10 * time.Second
	}
	conn, err := dialJSON(socketPath)
	if err != nil {
		return nil, err
	}
	return &Client{
		socketPath:            socketPath,
		timeout:               timeout,
		allowProtocolV6Attach: options.AllowProtocolV6Attach,
		conn:                  conn,
	}, nil
}

func DefaultSocketPath(session string) string {
	base := os.Getenv("TMPDIR")
	if base == "" {
		base = os.TempDir()
	}
	return filepath.Join(base, fmt.Sprintf("cmux-mux-%d", os.Getuid()), session+".sock")
}

func (c *Client) Close() error {
	if c.conn == nil {
		return nil
	}
	return c.conn.Close()
}

func (c *Client) SendRaw(ctx context.Context, req map[string]any) (map[string]any, error) {
	c.mu.Lock()
	defer c.mu.Unlock()
	request := make(map[string]any, len(req)+1)
	for k, v := range req {
		request[k] = v
	}
	if _, ok := request["id"]; !ok {
		request["id"] = c.nextRequestID()
	}
	requestID := request["id"]
	if err := c.conn.Send(ctx, c.timeout, request); err != nil {
		return nil, err
	}
	for {
		response, err := c.conn.Recv(ctx, c.timeout)
		if err != nil {
			return nil, err
		}
		if _, ok := response["event"].(string); ok {
			continue
		}
		if id, ok := response["id"]; ok && !sameJSONValue(id, requestID) {
			continue
		}
		return response, nil
	}
}

func (c *Client) request(ctx context.Context, cmd string, params map[string]any, out any) error {
	if params == nil {
		params = map[string]any{}
	}
	params["id"] = c.nextRequestID()
	params["cmd"] = cmd
	response, err := c.SendRaw(ctx, params)
	if err != nil {
		return err
	}
	if ok, _ := response["ok"].(bool); ok {
		data, _ := response["data"]
		encoded, err := json.Marshal(data)
		if err != nil {
			return &decodeError{msg: err.Error()}
		}
		if out == nil {
			return nil
		}
		if err := json.Unmarshal(encoded, out); err != nil {
			return &decodeError{msg: err.Error()}
		}
		return nil
	}
	msg, _ := response["error"].(string)
	if msg == "" {
		msg = "unknown error"
	}
	return &CommandError{Message: msg, ID: response["id"]}
}

func (c *Client) nextRequestID() uint64 {
	return c.nextID.Add(1)
}

func (c *Client) Identify(ctx context.Context) (IdentifyResult, error) {
	var result IdentifyResult
	err := c.request(ctx, "identify", nil, &result)
	if err == nil {
		c.protocol = &result.Protocol
	}
	return result, err
}

func (c *Client) ListWorkspaces(ctx context.Context) (Tree, error) {
	var result Tree
	return result, c.request(ctx, "list-workspaces", nil, &result)
}

func (c *Client) Send(ctx context.Context, surface uint64, opts SendOptions) error {
	params := map[string]any{"surface": surface}
	if opts.Text != nil {
		params["text"] = *opts.Text
	}
	if opts.Bytes != nil {
		params["bytes"] = base64.StdEncoding.EncodeToString(opts.Bytes)
	}
	if opts.Base64Bytes != "" {
		params["bytes"] = opts.Base64Bytes
	}
	return c.request(ctx, "send", params, nil)
}

func (c *Client) ReadScreen(ctx context.Context, surface uint64) (ReadScreenResult, error) {
	var result ReadScreenResult
	return result, c.request(ctx, "read-screen", map[string]any{"surface": surface}, &result)
}

func (c *Client) VtState(ctx context.Context, surface uint64) (VtStateResult, error) {
	var result VtStateResult
	return result, c.request(ctx, "vt-state", map[string]any{"surface": surface}, &result)
}

func (c *Client) NewTab(ctx context.Context, opts NewTabOptions) (SurfaceResult, error) {
	var result SurfaceResult
	return result, c.request(ctx, "new-tab", commandMap(opts), &result)
}

func (c *Client) NewBrowserTab(ctx context.Context, url string, opts NewBrowserTabOptions) (SurfaceResult, error) {
	params := commandMap(opts)
	params["url"] = url
	var result SurfaceResult
	return result, c.request(ctx, "new-browser-tab", params, &result)
}

func (c *Client) NewWorkspace(ctx context.Context, opts NewWorkspaceOptions) (SurfaceResult, error) {
	var result SurfaceResult
	return result, c.request(ctx, "new-workspace", commandMap(opts), &result)
}

func (c *Client) NewScreen(ctx context.Context, opts NewScreenOptions) (SurfaceResult, error) {
	var result SurfaceResult
	return result, c.request(ctx, "new-screen", commandMap(opts), &result)
}

func (c *Client) Split(ctx context.Context, pane uint64, dir string, opts SplitOptions) (SurfaceResult, error) {
	params := commandMap(opts)
	params["pane"] = pane
	params["dir"] = dir
	var result SurfaceResult
	return result, c.request(ctx, "split", params, &result)
}

func (c *Client) SetRatio(ctx context.Context, pane uint64, dir string, ratio float32) error {
	return c.request(ctx, "set-ratio", map[string]any{"pane": pane, "dir": dir, "ratio": ratio}, nil)
}

func (c *Client) SetDefaultColors(ctx context.Context, fg, bg *string) error {
	params := map[string]any{}
	if fg != nil {
		params["fg"] = *fg
	}
	if bg != nil {
		params["bg"] = *bg
	}
	return c.request(ctx, "set-default-colors", params, nil)
}

func (c *Client) CloseSurface(ctx context.Context, surface uint64) error {
	return c.request(ctx, "close-surface", map[string]any{"surface": surface}, nil)
}

func (c *Client) ClosePane(ctx context.Context, pane uint64) error {
	return c.request(ctx, "close-pane", map[string]any{"pane": pane}, nil)
}

func (c *Client) CloseScreen(ctx context.Context, screen uint64) error {
	return c.request(ctx, "close-screen", map[string]any{"screen": screen}, nil)
}

func (c *Client) CloseWorkspace(ctx context.Context, workspace uint64) error {
	return c.request(ctx, "close-workspace", map[string]any{"workspace": workspace}, nil)
}

func (c *Client) RenamePane(ctx context.Context, pane uint64, name string) error {
	return c.request(ctx, "rename-pane", map[string]any{"pane": pane, "name": name}, nil)
}

func (c *Client) RenameSurface(ctx context.Context, surface uint64, name string) error {
	return c.request(ctx, "rename-surface", map[string]any{"surface": surface, "name": name}, nil)
}

func (c *Client) RenameScreen(ctx context.Context, screen uint64, name string) error {
	return c.request(ctx, "rename-screen", map[string]any{"screen": screen, "name": name}, nil)
}

func (c *Client) RenameWorkspace(ctx context.Context, workspace uint64, name string) error {
	return c.request(ctx, "rename-workspace", map[string]any{"workspace": workspace, "name": name}, nil)
}

func (c *Client) ResizeSurface(ctx context.Context, surface uint64, cols, rows uint16) error {
	return c.request(ctx, "resize-surface", map[string]any{"surface": surface, "cols": cols, "rows": rows}, nil)
}

func (c *Client) FocusPane(ctx context.Context, pane uint64) error {
	return c.request(ctx, "focus-pane", map[string]any{"pane": pane}, nil)
}

func (c *Client) SelectTab(ctx context.Context, opts SelectTabOptions) error {
	return c.request(ctx, "select-tab", commandMap(opts), nil)
}

func (c *Client) SelectScreen(ctx context.Context, opts SelectOptions) error {
	return c.request(ctx, "select-screen", commandMap(opts), nil)
}

func (c *Client) SelectWorkspace(ctx context.Context, opts SelectOptions) error {
	return c.request(ctx, "select-workspace", commandMap(opts), nil)
}

func (c *Client) MoveTab(ctx context.Context, surface, pane uint64, index uint) error {
	return c.request(ctx, "move-tab", map[string]any{"surface": surface, "pane": pane, "index": index}, nil)
}

func (c *Client) MoveWorkspace(ctx context.Context, workspace uint64, index uint) error {
	return c.request(ctx, "move-workspace", map[string]any{"workspace": workspace, "index": index}, nil)
}

func (c *Client) ScrollSurface(ctx context.Context, surface uint64, delta int) error {
	return c.request(ctx, "scroll-surface", map[string]any{"surface": surface, "delta": delta}, nil)
}

func (c *Client) Subscribe(ctx context.Context) (*Stream, error) {
	return c.openStream(ctx, map[string]any{"id": c.nextRequestID(), "cmd": "subscribe"})
}

func (c *Client) AttachSurface(ctx context.Context, surface uint64) (*Stream, error) {
	protocol := c.protocol
	if protocol == nil {
		info, err := c.Identify(ctx)
		if err != nil {
			return nil, err
		}
		protocol = &info.Protocol
	}
	if *protocol > 6 || (*protocol > 5 && !c.allowProtocolV6Attach) {
		return nil, &protocolError{msg: fmt.Sprintf("unsupported attach protocol %d", *protocol)}
	}
	return c.openStream(ctx, map[string]any{"id": c.nextRequestID(), "cmd": "attach-surface", "surface": surface})
}

func (c *Client) openStream(ctx context.Context, request map[string]any) (*Stream, error) {
	conn, err := dialJSON(c.socketPath)
	if err != nil {
		return nil, err
	}
	if err := conn.Send(ctx, c.timeout, request); err != nil {
		_ = conn.Close()
		return nil, err
	}
	requestID := request["id"]
	var buffered []Event
	for {
		response, err := conn.Recv(ctx, c.timeout)
		if err != nil {
			_ = conn.Close()
			return nil, err
		}
		if _, ok := response["event"].(string); ok {
			buffered = append(buffered, parseEvent(response))
			continue
		}
		if !sameJSONValue(response["id"], requestID) {
			continue
		}
		if ok, _ := response["ok"].(bool); ok {
			return &Stream{conn: conn, timeout: c.timeout, buffered: buffered}, nil
		}
		msg, _ := response["error"].(string)
		if msg == "" {
			msg = "unknown error"
		}
		_ = conn.Close()
		return nil, &CommandError{Message: msg, ID: response["id"]}
	}
}

type Stream struct {
	conn     *jsonLineConn
	timeout  time.Duration
	buffered []Event
}

func (s *Stream) Close() error {
	return s.conn.Close()
}

func (s *Stream) Recv(ctx context.Context) (Event, error) {
	if len(s.buffered) > 0 {
		event := s.buffered[0]
		s.buffered = s.buffered[1:]
		return event, nil
	}
	for {
		value, err := s.conn.Recv(ctx, s.timeout)
		if err != nil {
			return nil, err
		}
		if _, ok := value["event"].(string); ok {
			return parseEvent(value), nil
		}
	}
}

type jsonLineConn struct {
	conn   net.Conn
	reader *bufio.Reader
	sendMu sync.Mutex
	readMu sync.Mutex
}

func dialJSON(socketPath string) (*jsonLineConn, error) {
	conn, err := net.Dial("unix", socketPath)
	if err != nil {
		return nil, &connectionError{msg: fmt.Sprintf("cannot connect to session socket %s: %v", socketPath, err)}
	}
	return &jsonLineConn{conn: conn, reader: bufio.NewReader(conn)}, nil
}

func (c *jsonLineConn) Close() error {
	return c.conn.Close()
}

func (c *jsonLineConn) Send(ctx context.Context, timeout time.Duration, value map[string]any) error {
	c.sendMu.Lock()
	defer c.sendMu.Unlock()
	if err := setWriteDeadline(ctx, c.conn, timeout); err != nil {
		return err
	}
	encoded, err := json.Marshal(value)
	if err != nil {
		return &decodeError{msg: err.Error()}
	}
	encoded = append(encoded, '\n')
	if _, err := c.conn.Write(encoded); err != nil {
		return classifyNetError(err, "socket write failed")
	}
	return nil
}

func (c *jsonLineConn) Recv(ctx context.Context, timeout time.Duration) (map[string]any, error) {
	c.readMu.Lock()
	defer c.readMu.Unlock()
	for {
		if err := ctx.Err(); err != nil {
			return nil, &timeoutError{msg: err.Error()}
		}
		deadline := time.Now().Add(timeout)
		if ctxDeadline, ok := ctx.Deadline(); ok && ctxDeadline.Before(deadline) {
			deadline = ctxDeadline
		}
		if err := c.conn.SetReadDeadline(deadline); err != nil {
			return nil, &connectionError{msg: err.Error()}
		}
		line, err := c.reader.ReadBytes('\n')
		if err != nil {
			return nil, classifyNetError(err, "socket read failed")
		}
		var value map[string]any
		if err := json.Unmarshal(line, &value); err != nil {
			return nil, &decodeError{msg: err.Error()}
		}
		return value, nil
	}
}

func setWriteDeadline(ctx context.Context, conn net.Conn, timeout time.Duration) error {
	deadline := time.Now().Add(timeout)
	if ctxDeadline, ok := ctx.Deadline(); ok && ctxDeadline.Before(deadline) {
		deadline = ctxDeadline
	}
	if err := conn.SetWriteDeadline(deadline); err != nil {
		return &connectionError{msg: err.Error()}
	}
	return nil
}

func classifyNetError(err error, prefix string) error {
	if errors.Is(err, os.ErrDeadlineExceeded) {
		return &timeoutError{msg: "session did not respond"}
	}
	var netErr net.Error
	if errors.As(err, &netErr) && netErr.Timeout() {
		return &timeoutError{msg: "session did not respond"}
	}
	return &connectionError{msg: fmt.Sprintf("%s: %v", prefix, err)}
}

func commandMap(value any) map[string]any {
	encoded, _ := json.Marshal(value)
	out := map[string]any{}
	_ = json.Unmarshal(encoded, &out)
	for key, item := range out {
		if item == nil {
			delete(out, key)
		}
	}
	return out
}

func sameJSONValue(a, b any) bool {
	aa, _ := json.Marshal(a)
	bb, _ := json.Marshal(b)
	return string(aa) == string(bb)
}
