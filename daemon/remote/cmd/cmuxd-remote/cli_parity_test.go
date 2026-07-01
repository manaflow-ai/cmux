package main

// TestCommandSpecParity calls system.command_spec through the relay socket and
// verifies that every flag the Mac CLI declares is also declared in the
// generated commandSpec, modulo intentional exceptions in commandOverrides.
//
// The test skips when no cmux socket is available so it does not block offline
// or CI builds. It DOES block when a socket is present — use it locally after
// updating the Mac CLI to catch relay drift before pushing.
//
// To regenerate commands_generated.go after the Mac CLI changes:
//
//	go generate ./cmd/cmuxd-remote/
//	git diff --exit-code daemon/remote/cmd/cmuxd-remote/commands_generated.go
import (
	"encoding/json"
	"fmt"
	"net"
	"os"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

func resolveSocketForTest(t *testing.T) string {
	t.Helper()
	if p := os.Getenv("CMUX_SOCKET_PATH"); p != "" {
		return p
	}
	home, err := os.UserHomeDir()
	if err != nil {
		t.Skip("cannot determine home dir")
	}
	data, err := os.ReadFile(filepath.Join(home, ".cmux", "socket_addr"))
	if err != nil {
		t.Skip("no cmux socket available (CMUX_SOCKET_PATH not set, ~/.cmux/socket_addr missing)")
	}
	return strings.TrimSpace(string(data))
}

func fetchCommandSpec(t *testing.T, socketPath string) map[string]commandEntry {
	t.Helper()
	conn, err := net.DialTimeout("unix", socketPath, 3*time.Second)
	if err != nil {
		// TCP relay address
		conn, err = net.DialTimeout("tcp", socketPath, 3*time.Second)
		if err != nil {
			t.Skipf("cannot reach cmux socket %s: %v", socketPath, err)
		}
	}
	defer conn.Close()

	req, _ := json.Marshal(map[string]any{
		"id":     "parity-test",
		"method": "system.command_spec",
		"params": map[string]any{},
	})
	conn.SetDeadline(time.Now().Add(5 * time.Second))
	if _, err := conn.Write(append(req, '\n')); err != nil {
		t.Fatalf("write: %v", err)
	}

	buf := make([]byte, 1<<20)
	n, err := conn.Read(buf)
	if err != nil {
		t.Fatalf("read: %v", err)
	}

	var envelope struct {
		OK     bool            `json:"ok"`
		Result json.RawMessage `json:"result"`
		Error  *struct {
			Code    string `json:"code"`
			Message string `json:"message"`
		} `json:"error"`
	}
	if err := json.Unmarshal(buf[:n], &envelope); err != nil {
		t.Fatalf("parse envelope: %v", err)
	}
	if !envelope.OK {
		if envelope.Error != nil && envelope.Error.Code == "method_not_found" {
			t.Skip("cmux does not yet implement system.command_spec (update Mac CLI first)")
		}
		t.Fatalf("system.command_spec returned ok=false: %v", envelope.Error)
	}

	var spec struct {
		Commands map[string]commandEntry `json:"commands"`
	}
	if err := json.Unmarshal(envelope.Result, &spec); err != nil {
		t.Fatalf("parse spec result: %v", err)
	}
	return spec.Commands
}

// commandEntry mirrors the JSON shape returned by system.command_spec.
type commandEntry struct {
	Method     string     `json:"method"`
	Flags      []flagSpec `json:"flags"`
	Positional string     `json:"positional,omitempty"`
	Aliases    []string   `json:"aliases,omitempty"`
}

type flagSpec struct {
	Name string `json:"name"`
	Type string `json:"type"`
}

func TestCommandSpecParity(t *testing.T) {
	socketPath := resolveSocketForTest(t)
	macSpec := fetchCommandSpec(t, socketPath)

	var failures []string

	for cmdName, macEntry := range macSpec {
		spec, ok := commandIndex[cmdName]
		if !ok {
			// Alias entries share a spec with the primary — skip them.
			// Unknown primaries are a real gap worth reporting.
			isAlias := false
			for _, e := range macSpec {
				for _, a := range e.Aliases {
					if a == cmdName {
						isAlias = true
					}
				}
			}
			if !isAlias {
				failures = append(failures, fmt.Sprintf(
					"command %q: in Mac CLI spec but not in relay commandIndex — add to commands_generated.go or run go generate",
					cmdName,
				))
			}
			continue
		}

		// Build the set of flags the relay declares (flagKeys + boolFlags + repeatKeys).
		declared := make(map[string]bool)
		for _, f := range spec.flagKeys {
			declared[f] = true
		}
		for _, f := range spec.repeatKeys {
			declared[f] = true
		}
		if spec.positionalKey != "" {
			declared[spec.positionalKey] = true
		}

		// Build the set of intentionally excepted flags from overrides.
		// clientOnlyFlags are fully supported (handled client-side), so they
		// count as declared even if not in flagKeys.
		if ov, ok := commandOverrides[cmdName]; ok {
			for _, f := range ov.clientOnlyFlags {
				declared[f] = true
			}
		}

		for _, macFlag := range macEntry.Flags {
			if !declared[macFlag.Name] {
				failures = append(failures, fmt.Sprintf(
					"command %q: Mac CLI flag --%s (%s) missing from relay — add to commands_generated.go or run go generate",
					cmdName, macFlag.Name, macFlag.Type,
				))
			}
		}
	}

	if len(failures) > 0 {
		t.Errorf("%d parity gap(s) detected:\n  %s", len(failures), strings.Join(failures, "\n  "))
		t.Log("Run: go generate ./daemon/remote/cmd/cmuxd-remote/ (with cmux running)")
	}
}
