package main

import (
	"bufio"
	"crypto/sha256"
	"encoding/hex"
	"net"
	"net/http"
	"net/http/httptest"
	"path/filepath"
	"strings"
	"testing"
	"time"
)

// sendAdminLeaseHeadersWithoutBody writes a POST /admin/leases request whose
// declared body never arrives, then returns the status the server answers with.
// A handler that reads the body before rejecting would block until the client
// gives up, so a missing response within the deadline fails the test.
func sendAdminLeaseHeadersWithoutBody(t *testing.T, serverURL string, extraHeaders string) int {
	t.Helper()
	addr := strings.TrimPrefix(serverURL, "http://")
	conn, err := net.Dial("tcp", addr)
	if err != nil {
		t.Fatalf("dial: %v", err)
	}
	defer conn.Close()
	request := "POST /admin/leases HTTP/1.1\r\n" +
		"Host: " + addr + "\r\n" +
		"Content-Type: application/json\r\n" +
		"Content-Length: 4096\r\n" +
		extraHeaders +
		"\r\n"
	if _, err := conn.Write([]byte(request)); err != nil {
		t.Fatalf("write request headers: %v", err)
	}
	_ = conn.SetReadDeadline(time.Now().Add(3 * time.Second))
	resp, err := http.ReadResponse(bufio.NewReader(conn), nil)
	if err != nil {
		t.Fatalf("server did not answer while the request body was withheld: %v", err)
	}
	defer resp.Body.Close()
	return resp.StatusCode
}

func TestAdminLeaseInstallRejectsUnauthenticatedRequestWithoutWaitingForBody(t *testing.T) {
	adminToken := "admin-token"
	sum := sha256.Sum256([]byte(adminToken))
	server := httptest.NewServer(newWebSocketPTYHandler(wsPTYServerConfig{
		PTYAuthLeaseFile: filepath.Join(t.TempDir(), "lease.json"),
		AdminTokenSHA256: hex.EncodeToString(sum[:]),
		Shell:            "/bin/sh",
	}, nil))
	defer server.Close()

	status := sendAdminLeaseHeadersWithoutBody(t, server.URL, "")
	if status != http.StatusForbidden {
		t.Fatalf("status = %d, want %d", status, http.StatusForbidden)
	}

	status = sendAdminLeaseHeadersWithoutBody(t, server.URL, "Authorization: Bearer wrong-token\r\n")
	if status != http.StatusForbidden {
		t.Fatalf("wrong bearer status = %d, want %d", status, http.StatusForbidden)
	}
}
