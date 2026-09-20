# SSH engine evaluation

Status: candidate evaluation, not an integration or security-completion claim.

The first loopback experiment used Homebrew libssh2 1.11.1 with an isolated
AsyncSSH 2.24.0 fixture. Host-key pin acceptance and rejection, password and
two-round keyboard-interactive authentication, Ed25519 authentication, SFTP,
and the expected negative paths were exercised. A non-sanitized run also
completed the corrected exec and PTY/resize cases.

The sanitized run must control the decision. Repeated AddressSanitizer runs
reproduced a heap buffer overflow during RSA public-key authentication inside
libssh2 1.11.1's `_libssh2_userauth_publickey` path. The write crosses the
34-byte allocation while processing the peer signature-algorithm list. This
engine is rejected for cmux iOS until a maintained fixed release is independently
verified; changing the fixture or disabling RSA would hide a required SSH
compatibility case.

Homebrew currently provides libssh 0.12.2. Its public API covers the required
authentication methods, PTY and exec channels, SFTP, forwarding, nonblocking
event integration, and security-key callbacks. It is the current candidate for
an iOS C shim, subject to these gates:

The signed `libssh-0.12.2.tar.xz` source was verified against libssh's published
release key `88A228D89B07C2C77D0C780903D5DF8CFDD3E8E7`. A host arm64 static
configuration completed with `WITH_SERVER=OFF`, `WITH_GSSAPI=OFF`,
`WITH_FIDO2=OFF`, `WITH_PKCS11_URI=OFF`, `WITH_PCAP=OFF`, `WITH_EXAMPLES=OFF`,
`BUILD_SHARED_LIBS=OFF`, and `WITH_SFTP=ON`. That proves the client-only source
configuration, not iOS compatibility. The produced host archive links against
Homebrew OpenSSL and cannot be shipped in the app.

The iOS build therefore needs a separately pinned, audited OpenSSL or mbedTLS
static dependency. Apple SDK crypto and CryptoKit cannot satisfy libssh's C
backend ABI. FIDO2 and PKCS#11 remain callback or external-provider work and
must not be represented as supported merely because the libssh headers expose
those APIs.

An arm64 iOS Simulator cross-build was then completed with libssh 0.12.2 and
Mbed TLS 3.6.7. The resulting libssh archive contains 79 objects and is arm64;
the source archives and output hashes are recorded here:

- libssh source SHA-256: `49560f677d96e3706a904ac2de1116e25f3680937d51e5c92198fcba4a1c1e9f`
- Mbed TLS source SHA-256: `a7e8bcbec0e6f761b4af24f25677626b35f762f68eef79c08677a363212d11f6`
- iOS-simulator libssh archive SHA-256: `473c4c9001d58ec26b13897b12a8a65a240dcf29c56aef277071bacc581e4599`

The Apple SDK probe incorrectly reported `memset_explicit` and
`explicit_bzero` as available during CMake configuration. The cross-build
must clear those generated `HAVE_*` values so libssh selects its existing
volatile-memory fallback. This is a build-system portability patch, not a
relaxation of secret-clearing behavior, and must be made reproducible in the
vendored recipe rather than edited in a build directory.

1. Build a reproducible arm64 iOS static library from pinned source releases,
   with the Mbed TLS backend and unused server features disabled. The checked-in
   recipe is `scripts/build-libssh-ios.sh`.
2. Expose a small Swift-owned wrapper that keeps all libssh objects on one
   actor or serial executor, translates callbacks into bounded async streams,
   and never passes untrusted shell strings to a subprocess.
3. Run the full fixture matrix: host-key rotation and pinning, password,
   keyboard-interactive, Ed25519/RSA/certificates, encrypted key passphrases,
   agent forwarding, jump hosts, PTY/exec/resize/cancellation, SFTP, local and
   remote forwarding, malformed packets, reconnect, and background/foreground.
4. Run the same matrix with AddressSanitizer/UndefinedBehaviorSanitizer on the
   host build and memory diagnostics on the iOS simulator. Keep the exact
   source digest, compiler flags, library license, and transitive dependency
   versions in the evidence packet.
5. Verify Network.framework integration and App Store packaging on a signed
   iOS build before the engine can become the product default.

No SSH engine is selected until all five gates pass. SwiftNIO SSH remains
insufficient for the full feature target because its authentication API does
not expose keyboard-interactive authentication.

References:

- https://www.libssh.org/2026/07/28/libssh-0-12-2-security-release/
- https://api.libssh.org/stable/libssh_tutor_authentication.html
- https://github.com/apple/swift-nio-ssh/blob/main/Sources/NIOSSH/User%20Authentication/UserAuthenticationMethod.swift
