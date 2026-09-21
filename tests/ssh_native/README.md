# Native SSH engine probe

Build the pinned host libraries with sanitizers, then compile this C harness
against those exact static archives and run the disposable AsyncSSH fixture:

```bash
CMUX_SSH_SANITIZERS=1 ./scripts/build-libssh-ios.sh macosx arm64 14.0 /tmp/cmux-ssh-host
./scripts/test-libssh-host.sh /tmp/cmux-ssh-host /tmp/cmux-ssh-host-results
```

The fixture uses a loopback listener and ephemeral mode-600 keys inside its own
private temporary directory. No user SSH configuration, keys, or known_hosts
are read or modified. Eleven cases exercise host-key and auth rejection,
passwords, two-round challenges, Ed25519/RSA, exec, terminal input/resize, and
SFTP reads. A failed case or sanitizer abort makes the command fail.

This validates the engine and crypto backend on macOS. It does not prove iOS
runtime integration, the Swift wrapper, hardware keys, certificates, forwarding,
jump hosts, reconnect, or full app behavior. Full acceptance remains in the
remote-terminal parity ledger.
