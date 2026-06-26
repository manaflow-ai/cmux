# Code-signing release verification & Gatekeeper triage

This doc covers how the release pipeline proves the *shipped* cmux DMG passes
the same code-signing checks an end user runs, and how to triage reports like
[#6670](https://github.com/manaflow-ai/cmux/issues/6670) where a clean install
appears to fail `codesign` / `spctl`.

## Release-time verification gate

`scripts/verify-released-app-bundle.sh` runs the exact end-user verification
flow against a `.app` (or, with `--dmg`, against the app extracted from the
shipped DMG):

```sh
scripts/verify-released-app-bundle.sh <app-path>      # verify a bundle directly
scripts/verify-released-app-bundle.sh --dmg <dmg>     # mount, ditto out, verify
scripts/verify-released-app-bundle.sh --self-test     # synthesize, sign, tamper
```

It asserts, in `CMUX_VERIFY_REQUIRE_NOTARIZED=1` mode (the default):

- `codesign --verify --deep --strict --verbose=4` succeeds (catches
  `invalid signature (code or signature have been modified)` and
  `a sealed resource is missing or invalid`),
- `codesign -dv` reports a **bound** Info.plist, a resolvable
  **Developer ID** authority chain (not `Authority=(unavailable)`), and a
  **stapled** notarization ticket,
- `spctl --assess --type execute --verbose=4` accepts the app as
  `source=Notarized Developer ID` (catches `internal error in Code Signing
  subsystem` and any non-acceptance).

`.github/workflows/release.yml` and `.github/workflows/nightly.yml` call
`--dmg` on the final notarized DMG **after** it is stapled and **before** it is
uploaded. The pipelines already stapled and `spctl`-checked the app *before* DMG
packaging; this gate additionally proves the copy a user actually extracts from
the DMG still verifies, so a packaging regression fails the release instead of
shipping. `tests/test_ci_released_dmg_signature_gate.py`
(in the `workflow-guard-tests` job) keeps the gate wired in both workflows.

## Triaging "clean install fails Gatekeeper" reports

When a user reports that a freshly installed/downloaded cmux fails
`codesign --verify` or `spctl --assess`, first determine whether the **artifact**
is bad or the **user's machine** is bad.

Download the published artifact and run the gate on a healthy Mac matching the
reporter's macOS version:

```sh
curl -L --fail https://github.com/manaflow-ai/cmux/releases/latest/download/cmux-macos.dmg -o /tmp/cmux-macos.dmg
scripts/verify-released-app-bundle.sh --dmg /tmp/cmux-macos.dmg
```

If this passes (as it did for stable `0.64.17` and the nightly on macOS `26.5`
during #6670 triage), the shipped artifact is correctly signed and notarized,
and the failure is **local to the reporter's machine**.

### Signs the failure is machine-side, not artifact-side

These symptoms, *especially when they affect every notarized Developer ID app
(both stable and nightly) identically*, indicate a degraded local code-signing /
trust subsystem (`syspolicyd` / `trustd` / `amfid` / the SystemPolicy database)
rather than a bad cmux build:

- `spctl` returns `internal error in Code Signing subsystem`,
- `codesign -dv` prints `Authority=(unavailable)` even though
  `TeamIdentifier` and a stapled ticket are present,
- `codesign -dv` prints `Info.plist=not bound` for an app that is bound
  elsewhere,
- the same failure reproduces across unrelated notarized apps.

A correctly signed app shows the full chain on a healthy machine:

```
Authority=Developer ID Application: Manaflow, Inc. (7WLXT3NR37)
Authority=Developer ID Certification Authority
Authority=Apple Root CA
Notarization Ticket=stapled
Info.plist entries=48
```

### User remediation for a degraded Security subsystem

- Reboot — many transient `trustd` / `syspolicyd` failures clear on restart.
- Confirm the failure reproduces on *other* notarized apps; if so, it is not
  cmux-specific.
- Ensure the Mac can reach Apple's OCSP / notarization endpoints (corporate
  proxies, Little Snitch, or MDM rules that block `ocsp.apple.com` /
  `api.apple-cloudkit.com` can break chain resolution).
- Check for endpoint-security / antivirus / MDM tooling that rewrites or strips
  extended attributes — script helpers under `Contents/Resources/bin` store
  their signatures in `com.apple.cs.*` xattrs, and a tool that strips them
  breaks the seal.
- Reset Gatekeeper assessment state: `sudo spctl --global-disable` then
  `sudo spctl --global-enable`, or rebuild it with
  `sudo /usr/libexec/syspolicy_check` / by removing
  `/var/db/SystemPolicyConfiguration` caches (last resort, requires reboot).
- Reinstall from the official DMG after verifying its checksum against the
  release asset digest.
