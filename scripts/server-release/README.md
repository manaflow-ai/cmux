# Server bootstrap candidates

`python3 scripts/server-release/render.py <plan.json> <new-output-directory>`
renders deterministic `install.sh`, `install.ps1`, `bootstrap.json` and
`SHA256SUMS` candidates. It does not sign, upload, configure routes or install
anything. Output must be a new directory so old signatures cannot survive a
rerender.

The public JSON plan has exactly these fields:

| Field | Value |
| --- | --- |
| `schema` | Integer `1` |
| `version` | Release version, such as `1.2.3` |
| `release_keys` | Exactly two distinct public Ed25519 keys, keyed by release key ID; 64 lowercase hex digits each |
| `macos_team_id` | Developer ID team, 10 uppercase letters/digits |
| `windows_publisher_thumbprints` | One or two approved signer thumbprints, 40 uppercase hex digits each |
| `archives` | One entry for each of the six targets below |

Targets are `x86_64-linux`, `aarch64-linux`, `aarch64-darwin`,
`x86_64-darwin`, `x86_64-windows` and `aarch64-windows`. Each entry has exactly
`url` (HTTPS, no credentials/query/fragment), `sha256` (64 lowercase hex digits)
and `size` (positive byte count, at most 1 GiB). Unix bootstrap archives contain
only the regular executable `bin/cmux` in a tar.gz; Windows archives contain
only `bin/cmux.exe` in a ZIP. These are bootstrap archives, separate from the
Rust store's tar.gz packages.

The installer verifies the archive before extraction and the platform signer
before execution. `--system` permits elevation of that verified binary; no
downloaded script is elevated. Installation and signed channel verification
remain owned by `cmux server install`. Public keys embedded in the script are
release metadata; Rust uses its baked trust roots, which the release pipeline
must match against the reviewed plan. Never put signing secrets in the plan.

Signing and publication remain separate: sign the exact rendered script bytes,
publish their raw Ed25519 detached signatures and checksums, and publish the
signed per-target channel manifests and packages before switching download
routes. A rendered candidate alone does not make the documented URLs work.

Run `python3 scripts/server-release/test_render.py -v` for portable tests. They
use actual local TLS downloads, hashing, tar extraction and harmless child
processes; platform identity, macOS signing and sudo are fixtures. Windows
PowerShell, Authenticode and real service installation still need their native
gates before publication. Bootstrap failures use invariant diagnostic IDs;
there are no UI or catalog strings in this tooling.

Platform references: [Apple signing requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements)
and [PowerShell Authenticode verification](https://learn.microsoft.com/en-us/powershell/module/microsoft.powershell.security/get-authenticodesignature).
