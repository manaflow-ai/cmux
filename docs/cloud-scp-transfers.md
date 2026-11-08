# Cloud SCP transfers

`cmux vm push` copies files with system OpenSSH/SFTP through the app's existing userspace WireGuard hub. `--watch`, `vm dev`, and `vm run --sync` call the same push path. `vm pull` still uses exec. `--secret` keeps the existing cmux file receive path.

The CLI creates an Ed25519 key in an owner-only temporary directory. `vm.scp_info` sends only the public key to the signed-in `/api/vm/[id]/scp-endpoint` route. The route checks account access and wake limits. The provider installs the public key for the guest `cmux` user with `restrict` and a UTC expiry 15 minutes ahead. A file lock protects concurrent updates, and later transfers remove expired cmux keys while preserving other keys. The private key never reaches the app or backend.

The provider reads the guest host public key through its authenticated HTTPS exec API. The app creates a loopback forward to the guest's private port 22 through the shared WireGuard hub. OpenSSH requires that exact host key, disables user SSH configuration and connection sharing, and uses only the transfer key. There is no public SSH gateway, trust on first use, password, or Freestyle identity token. Existing forwards close when the machine leaves the account, on sign-out, or when the app exits. Idle forwards hold no tunnel lease.

File data stays outside the control API and command arguments. The CLI stages a local snapshot and hashes it in 1 MiB blocks. SCP uploads into an owner-only guest directory beside the destination. SHA-256 must match before a file is renamed into place or a directory is extracted. Directory pushes merge with the destination and do not promise an atomic tree replacement. The existing 256 MiB limit remains. Interrupted transfers can leave a private staging directory if cleanup cannot reconnect; the CLI reports that failure. Key expiry denies new SSH authentication and does not terminate a session already in progress.

Each grant request opens a fresh authenticated local control connection and closes it after the reply. The watcher and the file transfer do not retain an idle control socket. A grant renewal uses the same rule and never replays an uncertain upload.

Local transfer failures use `vm.file_transfer_failure` to send a bounded phase, failure category, and optional subprocess exit code to the signed-in app. The app records a file operation with a failed phase and supplies a copyable diagnostic reference. The normal Cloud exporter attaches the client channel, version, and revision. No file paths, contents, SSH keys, commands, or stderr enter the report. A missing app or failed report leaves the original CLI error intact. Preparation API failures are already recorded by the app and are not reported twice.

## Verification

`python3 tests/test_vm_scp.py /path/to/built/cmux` runs real OpenSSH and SFTP against an isolated local SSH server, with a mock app socket. It covers binary data, special path characters, parent creation, modes, exclusions, checksum failure, host-key mismatch, concurrent transfers, and watch updates after the control connection closes. `CloudSCPIntegrationTests` runs it with the app's bundled CLI.

Before merge, also run the signed-in tagged app against a disposable Cloud machine. Push a binary file and an excluded directory, compare guest hashes and contents, run two transfers together, and check that no `.cmux-push.*` staging directories remain. Record the app revision and test results. Destroy only that test machine after verification.
