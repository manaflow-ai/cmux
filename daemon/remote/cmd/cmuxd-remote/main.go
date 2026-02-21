package main

import (
	"bufio"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"os"
)

var version = "dev"

type rpcRequest struct {
	ID     any            `json:"id"`
	Method string         `json:"method"`
	Params map[string]any `json:"params"`
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

func main() {
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
		if err := fs.Parse(args[1:]); err != nil {
			return 2
		}
		if !*stdio {
			_, _ = fmt.Fprintln(stderr, "serve requires --stdio")
			return 2
		}
		if err := runStdioServer(stdin, stdout); err != nil {
			_, _ = fmt.Fprintf(stderr, "serve failed: %v\n", err)
			return 1
		}
		return 0
	default:
		usage(stderr)
		return 2
	}
}

func usage(w io.Writer) {
	_, _ = fmt.Fprintln(w, "Usage:")
	_, _ = fmt.Fprintln(w, "  cmuxd-remote version")
	_, _ = fmt.Fprintln(w, "  cmuxd-remote serve --stdio")
}

func runStdioServer(stdin io.Reader, stdout io.Writer) error {
	scanner := bufio.NewScanner(stdin)
	writer := bufio.NewWriter(stdout)
	defer writer.Flush()

	for scanner.Scan() {
		line := scanner.Bytes()
		if len(line) == 0 {
			continue
		}

		var req rpcRequest
		if err := json.Unmarshal(line, &req); err != nil {
			if err := writeResponse(writer, rpcResponse{
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

		resp := handleRequest(req)
		if err := writeResponse(writer, resp); err != nil {
			return err
		}
	}

	if err := scanner.Err(); err != nil {
		return err
	}
	return nil
}

func writeResponse(w *bufio.Writer, resp rpcResponse) error {
	payload, err := json.Marshal(resp)
	if err != nil {
		return err
	}
	if _, err := w.Write(payload); err != nil {
		return err
	}
	if err := w.WriteByte('\n'); err != nil {
		return err
	}
	return w.Flush()
}

func handleRequest(req rpcRequest) rpcResponse {
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
					"proxy.http_connect",
					"proxy.socks5",
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
