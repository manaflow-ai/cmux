# Relay TLS on managed Macs

[日本語](relay-tls-enterprise.ja.md)

Native Iroh relay connections on macOS use Apple's system certificate
validation. Enterprise roots installed and trusted for TLS by your administrator
in the System keychain are honored, including Zscaler inspection roots. Merely
installing a certificate does not grant it trust.

Hostname, validity dates, chain, and macOS trust restrictions remain enforced.
There is no certificate bypass or fallback after macOS rejects a certificate.
macOS owns public and enterprise root policy; cmux does not copy keychain roots
into a separate bundle. `SSL_CERT_FILE` and `SSL_CERT_DIR` do not override this
native macOS Iroh policy.

iOS retains its embedded WebPKI trust policy. This fixes the Mac side of mobile
connectivity; installing a root on a Mac does not make it trusted on an iPhone.
URLSession and ordinary WebSocket clients retain their existing trust behavior.
SSH host-key verification and Iroh's end-to-end peer identity authentication are
separate and unchanged.

## Diagnose and remediate

Native relay errors record only the host, port, and fixed cause in the macOS
unified-log category `RelayTLS`. The readiness error includes the same cause
when available. In Settings → Networking, the same safe message remains visible
while the Mac retries, and clears when relay readiness recovers. Diagnostics exclude URL usernames, passwords, paths, queries,
relay tokens, and raw provider error text.

```sh
log show --last 10m --style compact --predicate 'subsystem == "com.cmux" AND category == "RelayTLS"'
```

| Cause | Next step |
| --- | --- |
| `UnknownIssuer` | Ask IT to verify the inspection root's TLS trust and the server's intermediate chain. |
| `SystemTrustFailed` | Ask IT to review system trust restrictions and the certificate chain. |
| `HostnameMismatch` | Check the configured relay hostname and the relay or inspection gateway's certificate. |
| `CertificateExpired` / `CertificateNotYetValid` | Check the Mac's clock and ask IT or the relay operator to renew or correct the certificate. |
| `CertificateRevoked` | Ask the certificate owner to replace the revoked certificate. |
| `TLSFailed` | Check TLS protocol compatibility with the relay or inspection gateway. |
| `NetworkFailed` | Check DNS, routing, firewall rules, and relay reachability. This is separate from certificate trust. |
| `Other` | TLS may have succeeded but relay authentication or its protocol failed; check relay service status. |

After IT corrects trust or the chain, reconnect or restart cmux for a fresh
handshake. Do not export credentials or disable certificate validation as a
workaround. Trusting a root does not repair a firewall rule or an inspection
gateway that blocks the relay's WebSocket protocol.

## Deterministic verification

Run only on a disposable macOS VM with Xcode 16 or later and passwordless sudo:

```sh
python3 tests/relay_tls/system_keychain.py \
  --allow-system-keychain --diagnostics --output relay-tls-results
```

The harness builds a consumer of the exact native framework pinned by cmux,
generates a test CA, and checks rejection before installation. It installs that
CA in the System keychain, confirms Apple's trust evaluation, and requires Iroh
to send application data over the validated TLS connection. It also rejects a
wrong hostname, expired leaf, and the root after removal, and checks the native
failure categories. Omit `--diagnostics` when reproducing an older framework
without the diagnostic API. Cleanup removes only
the generated CA. Results and logs are saved in the output directory. No
Zscaler tenant, corporate credentials, or production relay is needed.
