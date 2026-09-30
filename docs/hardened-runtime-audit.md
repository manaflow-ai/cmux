# Hardened-runtime entitlement audit

The Developer ID signing path is `scripts/sign-cmux-bundle.sh`. Stable, nightly,
and RC provide their channel entitlement file; `scripts/build-sign-upload.sh`
uses the legacy `cmux.entitlements`. Native helpers use `cmux-helper.entitlements`.
Debug builds use a different signing path and cannot establish release compatibility.

| Entitlement | Main app | Native helpers | Reason |
| --- | --- | --- | --- |
| `disable-library-validation` | Removed | Removed | Bundled libraries are signed inside-out with the app's Developer ID. Apple frameworks remain loadable. Sidebar extensions run out of process. |
| `allow-unsigned-executable-memory` | Removed | Removed | No identified consumer requires unrestricted executable memory. JavaScriptCore uses the narrower `allow-jit` capability. |
| `allow-jit` | Retained | Removed | Custom sidebar JavaScript and Highlightr syntax highlighting use JavaScriptCore in the app process; sidebar render workers re-execute that same binary. Native CLI and Computer Use helpers do not host those consumers. |

The Cloud tunnel entitlement reconciler already removed the two broader keys
from the final app signature when signing stable, nightly, and RC with their
required tunnel profiles. Removing them from the source files makes that policy
explicit and also covers the legacy release path. The reconciler's existing
compatibility guard remains in place.

The original library-validation opt-out was introduced by `a2457f1d5e` to address
reported menu lag. The unsigned-memory and JIT keys were added by `fe082cd213`
without individual rationale. The signing refactor in
https://github.com/manaflow-ai/cmux/pull/2908 copied them into the channel files.
Current JavaScriptCore consumers explain retaining JIT independently of those
historical changes; Ghostty's terminal renderer does not itself require it.

A macOS C probe linked to JavaScriptCore, ad-hoc signed with `--options runtime`,
evaluated a 10-million-iteration JavaScript loop with identical results under
both policies. CPU times were 0.0154/0.0172 seconds with `allow-jit`, versus
0.3875/0.3928 seconds without it. This is a narrow runtime probe, not app or
Developer ID verification, but it demonstrates the performance regression from
removing JIT.

`tests/test_hardened_runtime_entitlements.py` signs real Mach-O fixtures, reads
the resulting signatures, and verifies the production app/helper policy. It
also mutates signed fixture bundles and checks the artifact verifier rejects
broad main-app relaxations and helper exceptions, including nested SSH payloads.
It runs in the macOS CLI lane without launching an app. The production signer
runs `scripts/verify-hardened-runtime-entitlements.py` over every embedded Mach-O
slice, so exceptions cannot hide in a foreign architecture or nested helper.

Release acceptance additionally requires a Developer ID signed artifact and
runtime checks of terminal rendering, custom sidebars, syntax highlighting,
Sparkle update discovery, WebAuthn, and helper execution. The fixture tests and
a tagged Debug build do not substitute for those checks. PR evidence records
which release checks actually ran.
