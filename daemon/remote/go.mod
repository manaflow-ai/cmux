module github.com/manaflow-ai/cmux/daemon/remote

go 1.25.0

// The exact Go of every shipped cmuxd-remote build (nightly, release, and the
// HQ Linux nightly-next builder). Same Go, same bytes: the binaries and the
// app's CMUXRemoteDaemonManifestJSON hashes depend on it. setup-go reads this
// line (go-version-file); scripts/build_remote_daemon_release_assets.sh
// refuses any other Go. A bump also adds the sha256 of the new Go to HQ
// build-fleet/nightly-next-linux/go-sha256.txt, or the Linux build fails.
toolchain go1.26.10

require (
	github.com/creack/pty v1.1.24
	golang.org/x/sys v0.44.0
	nhooyr.io/websocket v1.8.17
)
