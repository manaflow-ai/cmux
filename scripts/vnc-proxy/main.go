package main

import (
	"bufio"
	"context"
	"errors"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"

	"nhooyr.io/websocket"
)

type proxyConfig struct {
	listenHost    string
	listenPort    int
	targetHost    string
	targetPort    int
	websocketPath string
	webRoot       string
	dialTimeout   time.Duration
	idleTimeout   time.Duration
}

func getenv(key, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(key)); value != "" {
		return value
	}
	return fallback
}

func parsePort(raw string, fallback int) (int, error) {
	if strings.TrimSpace(raw) == "" {
		return fallback, nil
	}
	value, err := strconv.Atoi(raw)
	if err != nil {
		return 0, fmt.Errorf("invalid port %q: %w", raw, err)
	}
	if value <= 0 || value > 65535 {
		return 0, fmt.Errorf("port %d out of range", value)
	}
	return value, nil
}

func parseDuration(raw string, fallback time.Duration) (time.Duration, error) {
	if strings.TrimSpace(raw) == "" {
		return fallback, nil
	}
	d, err := time.ParseDuration(raw)
	if err != nil {
		return 0, fmt.Errorf("invalid duration %q: %w", raw, err)
	}
	if d < 0 {
		return 0, fmt.Errorf("duration %s must be non-negative", d)
	}
	return d, nil
}

func loadConfig() (proxyConfig, error) {
	listenHost := getenv("CMUX_VNC_PROXY_HOST", "0.0.0.0")
	listenPort, err := parsePort(getenv("CMUX_VNC_PROXY_PORT", "39380"), 39380)
	if err != nil {
		return proxyConfig{}, err
	}
	targetHost := getenv("CMUX_VNC_TARGET_HOST", "127.0.0.1")
	targetPort, err := parsePort(getenv("CMUX_VNC_TARGET_PORT", "5901"), 5901)
	if err != nil {
		return proxyConfig{}, err
	}
	wsPath := getenv("CMUX_VNC_WS_PATH", "/websockify")
	if !strings.HasPrefix(wsPath, "/") {
		wsPath = "/" + wsPath
	}
	webRoot := getenv("CMUX_VNC_WEB_DIR", "/usr/share/novnc")
	dialTimeout, err := parseDuration(getenv("CMUX_VNC_DIAL_TIMEOUT", "5s"), 5*time.Second)
	if err != nil {
		return proxyConfig{}, err
	}
	idleTimeout, err := parseDuration(getenv("CMUX_VNC_IDLE_TIMEOUT", "0"), 0)
	if err != nil {
		return proxyConfig{}, err
	}
	return proxyConfig{
		listenHost:    listenHost,
		listenPort:    listenPort,
		targetHost:    targetHost,
		targetPort:    targetPort,
		websocketPath: wsPath,
		webRoot:       webRoot,
		dialTimeout:   dialTimeout,
		idleTimeout:   idleTimeout,
	}, nil
}

func (cfg proxyConfig) targetAddr() string {
	return net.JoinHostPort(cfg.targetHost, strconv.Itoa(cfg.targetPort))
}

func (cfg proxyConfig) listenAddr() string {
	return net.JoinHostPort(cfg.listenHost, strconv.Itoa(cfg.listenPort))
}

func main() {
	log.SetFlags(log.LstdFlags | log.LUTC)

	cfg, err := loadConfig()
	if err != nil {
		log.Fatalf("failed to load config: %v", err)
	}

	handler := newServeMux(cfg)

	if info, err := os.Stat(cfg.webRoot); err != nil {
		log.Printf("warning: static directory %q unavailable: %v", cfg.webRoot, err)
	} else if !info.IsDir() {
		log.Printf("warning: static path %q is not a directory", cfg.webRoot)
	}

	httpServer := &http.Server{
		Addr:              cfg.listenAddr(),
		Handler:           handler,
		ReadHeaderTimeout: 5 * time.Second,
		IdleTimeout:       90 * time.Second,
	}

	log.Printf(
		"cmux VNC proxy listening on %s, forwarding websockets at %s to %s (static from %s)",
		cfg.listenAddr(),
		cfg.websocketPath,
		cfg.targetAddr(),
		filepath.Clean(cfg.webRoot),
	)

	if err := httpServer.ListenAndServe(); err != nil && !errors.Is(err, http.ErrServerClosed) {
		log.Fatalf("server exited: %v", err)
	}
}

func newServeMux(cfg proxyConfig) http.Handler {
	mux := http.NewServeMux()

	wsHandler := newWebsocketHandler(cfg)
	mux.Handle(cfg.websocketPath, wsHandler)
	if !strings.HasSuffix(cfg.websocketPath, "/") {
		mux.Handle(cfg.websocketPath+"/", wsHandler)
	}

	fileServer := http.FileServer(http.Dir(cfg.webRoot))
	mux.Handle("/", withSecurityHeaders(fileServer))

	return loggingMiddleware(mux)
}

func withSecurityHeaders(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		h := w.Header()
		h.Set("X-Content-Type-Options", "nosniff")
		h.Set("X-Frame-Options", "SAMEORIGIN")
		h.Set("Referrer-Policy", "no-referrer")
		h.Set("Cross-Origin-Resource-Policy", "same-origin")
		next.ServeHTTP(w, r)
	})
}

func loggingMiddleware(next http.Handler) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		start := time.Now()
		srw := &statusRecorder{ResponseWriter: w, status: http.StatusOK}
		next.ServeHTTP(srw, r)
		log.Printf(
			"%s %s %d %s",
			r.Method,
			r.URL.Path,
			srw.status,
			time.Since(start).Round(time.Millisecond),
		)
	})
}

type statusRecorder struct {
	http.ResponseWriter
	status int
}

func (sr *statusRecorder) WriteHeader(status int) {
	sr.status = status
	sr.ResponseWriter.WriteHeader(status)
}

func (sr *statusRecorder) Hijack() (net.Conn, *bufio.ReadWriter, error) {
	h, ok := sr.ResponseWriter.(http.Hijacker)
	if !ok {
		return nil, nil, fmt.Errorf("status recorder does not support hijacking")
	}
	return h.Hijack()
}

func (sr *statusRecorder) Flush() {
	if f, ok := sr.ResponseWriter.(http.Flusher); ok {
		f.Flush()
	}
}

func (sr *statusRecorder) Push(target string, opts *http.PushOptions) error {
	if p, ok := sr.ResponseWriter.(http.Pusher); ok {
		return p.Push(target, opts)
	}
	return http.ErrNotSupported
}

func newWebsocketHandler(cfg proxyConfig) http.Handler {
	return http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if !isWebSocketRequest(r) {
			http.Error(w, "websocket upgrade required", http.StatusUpgradeRequired)
			return
		}

		dialer := &net.Dialer{Timeout: cfg.dialTimeout}

		ctx := r.Context()

		backend, err := dialer.DialContext(ctx, "tcp", cfg.targetAddr())
		if err != nil {
			log.Printf("backend dial failed: %v", err)
			http.Error(w, "backend unavailable", http.StatusBadGateway)
			return
		}

		defer backend.Close()

		opts := &websocket.AcceptOptions{InsecureSkipVerify: true}
		if subprotocols := readRequestedSubprotocols(r); len(subprotocols) > 0 {
			opts.Subprotocols = subprotocols
		}
		conn, err := websocket.Accept(w, r, opts)
		if err != nil {
			log.Printf("websocket accept failed: %v", err)
			return
		}
		defer conn.Close(websocket.StatusInternalError, "internal error")

		if cfg.idleTimeout > 0 {
			_ = backend.SetDeadline(time.Now().Add(cfg.idleTimeout))
		}

		log.Printf("websocket connection established from %s", r.RemoteAddr)

		bridgeCtx, cancel := context.WithCancel(ctx)
		defer cancel()

		wsConn := websocket.NetConn(bridgeCtx, conn, websocket.MessageBinary)
		defer wsConn.Close()

		errCh := make(chan error, 2)

		go func() {
			_, err := io.Copy(backend, wsConn)
			errCh <- err
		}()

		go func() {
			_, err := io.Copy(wsConn, backend)
			errCh <- err
		}()

		var copyErr error
		select {
		case copyErr = <-errCh:
		case <-bridgeCtx.Done():
			copyErr = bridgeCtx.Err()
		}

		if copyErr != nil && !errors.Is(copyErr, io.EOF) && !errors.Is(copyErr, context.Canceled) {
			var netErr net.Error
			if errors.As(copyErr, &netErr) && netErr.Timeout() {
				log.Printf("proxy connection closed due to timeout: %v", netErr)
			} else if !errors.Is(copyErr, net.ErrClosed) {
				log.Printf("proxy connection error: %v", copyErr)
			}
		}

		conn.Close(websocket.StatusNormalClosure, "")
		log.Printf("websocket connection closed from %s", r.RemoteAddr)
	})
}

func readRequestedSubprotocols(r *http.Request) []string {
	rawValues := r.Header.Values("Sec-WebSocket-Protocol")
	if len(rawValues) == 0 {
		return nil
	}
	var subprotocols []string
	for _, rawValue := range rawValues {
		for _, candidate := range strings.Split(rawValue, ",") {
			if protocol := strings.TrimSpace(candidate); protocol != "" {
				subprotocols = append(subprotocols, protocol)
			}
		}
	}
	return subprotocols
}

func isWebSocketRequest(r *http.Request) bool {
	if !strings.EqualFold(r.Method, http.MethodGet) {
		return false
	}
	connection := r.Header.Get("Connection")
	if connection == "" {
		return false
	}
	for _, token := range strings.Split(connection, ",") {
		if strings.EqualFold(strings.TrimSpace(token), "upgrade") {
			return strings.EqualFold(r.Header.Get("Upgrade"), "websocket")
		}
	}
	return false
}
