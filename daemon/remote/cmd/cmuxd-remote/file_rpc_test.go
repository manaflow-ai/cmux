package main

import (
	"encoding/base64"
	"os"
	"path/filepath"
	"testing"
)

func TestFileRPCAdvertisesCapabilities(t *testing.T) {
	response := (&rpcServer{}).handleRequest(rpcRequest{
		ID:     1,
		Method: "hello",
		Params: map[string]any{},
	})
	if !response.OK {
		t.Fatalf("hello failed: %+v", response.Error)
	}
	result, ok := response.Result.(map[string]any)
	if !ok {
		t.Fatalf("hello result type = %T, want map[string]any", response.Result)
	}
	capabilities, ok := result["capabilities"].([]string)
	if !ok {
		t.Fatalf("hello capabilities type = %T, want []string", result["capabilities"])
	}
	for _, required := range []string{"file.read", "fs.stat"} {
		if !containsString(capabilities, required) {
			t.Errorf("hello capabilities missing %q: %v", required, capabilities)
		}
	}
}

func TestFileRPCStatAndRead(t *testing.T) {
	project := t.TempDir()
	configDirectory := filepath.Join(project, ".cmux")
	if err := os.Mkdir(configDirectory, 0o755); err != nil {
		t.Fatalf("create config directory: %v", err)
	}
	configPath := filepath.Join(configDirectory, "dock.json")
	configData := []byte(`{"controls":[{"title":"Logs","command":"tail -f app.log"}]}`)
	if err := os.WriteFile(configPath, configData, 0o644); err != nil {
		t.Fatalf("write config: %v", err)
	}

	server := &rpcServer{}
	stat := server.handleRequest(rpcRequest{
		ID:     1,
		Method: "fs.stat",
		Params: map[string]any{"path": configPath},
	})
	if !stat.OK {
		t.Fatalf("fs.stat failed: %+v", stat.Error)
	}
	statResult, ok := stat.Result.(map[string]any)
	if !ok {
		t.Fatalf("fs.stat result type = %T, want map[string]any", stat.Result)
	}
	if got := statResult["exists"]; got != true {
		t.Errorf("fs.stat exists = %#v, want true", got)
	}
	if got := statResult["type"]; got != "file" {
		t.Errorf("fs.stat type = %#v, want file", got)
	}
	if got := statResult["size"]; got != int64(len(configData)) {
		t.Errorf("fs.stat size = %#v, want %d", got, len(configData))
	}

	read := server.handleRequest(rpcRequest{
		ID:     2,
		Method: "file.read",
		Params: map[string]any{"path": configPath},
	})
	if !read.OK {
		t.Fatalf("file.read failed: %+v", read.Error)
	}
	readResult, ok := read.Result.(map[string]any)
	if !ok {
		t.Fatalf("file.read result type = %T, want map[string]any", read.Result)
	}
	decoded, err := base64.StdEncoding.DecodeString(readResult["data_base64"].(string))
	if err != nil {
		t.Fatalf("decode file.read data: %v", err)
	}
	if string(decoded) != string(configData) {
		t.Errorf("file.read data = %q, want %q", decoded, configData)
	}
}

func TestFileRPCMissingDirectoryAndBounds(t *testing.T) {
	server := &rpcServer{}
	missing := filepath.Join(t.TempDir(), "missing.json")
	stat := server.handleRequest(rpcRequest{
		ID:     1,
		Method: "fs.stat",
		Params: map[string]any{"path": missing},
	})
	if !stat.OK {
		t.Fatalf("fs.stat missing path failed: %+v", stat.Error)
	}
	statResult := stat.Result.(map[string]any)
	if got := statResult["exists"]; got != false {
		t.Errorf("fs.stat missing exists = %#v, want false", got)
	}

	assertRPCErrorCode(t, server.handleRequest(rpcRequest{
		ID:     2,
		Method: "file.read",
		Params: map[string]any{"path": missing},
	}), "file_not_found")
	assertRPCErrorCode(t, server.handleRequest(rpcRequest{
		ID:     3,
		Method: "file.read",
		Params: map[string]any{"path": t.TempDir()},
	}), "file_not_regular")
	assertRPCErrorCode(t, server.handleRequest(rpcRequest{
		ID:     4,
		Method: "fs.stat",
		Params: map[string]any{"path": "  "},
	}), "invalid_params")

	largePath := filepath.Join(t.TempDir(), "large.json")
	if err := os.WriteFile(largePath, make([]byte, 1024*1024+1), 0o644); err != nil {
		t.Fatalf("write oversized file: %v", err)
	}
	assertRPCErrorCode(t, server.handleRequest(rpcRequest{
		ID:     5,
		Method: "file.read",
		Params: map[string]any{"path": largePath},
	}), "file_too_large")
}

func assertRPCErrorCode(t *testing.T, response rpcResponse, code string) {
	t.Helper()
	if response.OK {
		t.Fatalf("response unexpectedly succeeded: %+v", response.Result)
	}
	if response.Error == nil || response.Error.Code != code {
		t.Fatalf("error = %+v, want code %q", response.Error, code)
	}
}

func containsString(values []string, target string) bool {
	for _, value := range values {
		if value == target {
			return true
		}
	}
	return false
}
