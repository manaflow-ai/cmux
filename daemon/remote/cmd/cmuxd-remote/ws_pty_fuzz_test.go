package main

import (
	"os"
	"path/filepath"
	"testing"
)

func FuzzConsumeWebSocketLease(f *testing.F) {
	f.Add(`{"version":1,"token_sha256":"2bb80d537b1da3e38bd30361aa855686bde0ba2cf9c27ffb6b3874b764d66e16","expires_at_unix":4102444800,"session_id":"sess","single_use":false}`, "secret", "sess")
	f.Add(`{"version":1,"token_sha256":"bad","expires_at_unix":0,"single_use":true}`, "secret", "")
	f.Add(`not-json`, "secret", "sess")

	f.Fuzz(func(t *testing.T, leaseJSON string, token string, sessionID string) {
		if len(leaseJSON) > 1<<20 {
			t.Skip("lease fixture too large")
		}
		path := filepath.Join(t.TempDir(), "lease.json")
		if err := os.WriteFile(path, []byte(leaseJSON), 0o600); err != nil {
			t.Fatalf("write lease: %v", err)
		}
		_ = consumeWebSocketLease(path, wsAuthFrame{
			Type:      "auth",
			Token:     token,
			SessionID: sessionID,
			Cols:      80,
			Rows:      24,
		})
	})
}

func FuzzNormalizePTYSize(f *testing.F) {
	f.Add(80, 24)
	f.Add(0, 0)
	f.Add(-1, -100)
	f.Add(1_000_000, 1_000_000)

	f.Fuzz(func(t *testing.T, cols int, rows int) {
		gotCols, gotRows := normalizePTYSize(cols, rows)
		if gotCols <= 0 || gotRows <= 0 {
			t.Fatalf("normalizePTYSize(%d, %d) = %dx%d, expected positive dimensions", cols, rows, gotCols, gotRows)
		}
		if gotCols > maxPTYDimension || gotRows > maxPTYDimension {
			t.Fatalf("normalizePTYSize(%d, %d) = %dx%d, expected <= %d", cols, rows, gotCols, gotRows, maxPTYDimension)
		}
	})
}
