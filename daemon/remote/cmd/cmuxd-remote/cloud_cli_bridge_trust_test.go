package main

import (
	"net"
	"os"
	"path/filepath"
	"testing"
)

// The CLI falls back to the shared /tmp bridge path; another local user can
// create a socket there first. The CLI must use only a socket this user
// owns, and never through a symlink.
func TestCloudCLIBridgeSocketMustBeOwnedByTheCurrentUser(t *testing.T) {
	dir, err := os.MkdirTemp("/tmp", "cmux-bridge-trust-")
	if err != nil {
		t.Fatal(err)
	}
	defer os.RemoveAll(dir)
	socket := filepath.Join(dir, "b.sock")
	listener, err := net.Listen("unix", socket)
	if err != nil {
		t.Fatal(err)
	}
	defer listener.Close()
	uid := uint32(os.Getuid())

	if got := cloudCLIBridgeSocketIfTrusted(socket, uid); got != socket {
		t.Fatalf("own socket: got %q, want %q", got, socket)
	}
	if got := cloudCLIBridgeSocketIfTrusted(socket, uid+1); got != "" {
		t.Fatalf("socket owned by another uid was trusted: %q", got)
	}
	link := filepath.Join(dir, "link.sock")
	if err := os.Symlink(socket, link); err != nil {
		t.Fatal(err)
	}
	if got := cloudCLIBridgeSocketIfTrusted(link, uid); got != "" {
		t.Fatalf("symlinked socket was trusted: %q", got)
	}
}
