# nightly.yml `build-sign-notarize-nightly`: notes moved out of the workflow

Moved from `.github/workflows/nightly.yml` to keep it under GitHub's 500 KB workflow file limit
(tests/test_ci_workflow_file_size.py). Each section's number is the `#N` in the job's `# Why:` line.

## 1

Above: `environment: ${{ needs.decide.outputs.environment }}`

Production secrets: GitHub releases them only to protected refs (the
environment's deployment branch policy: main, tags v*). The nightly-next
track uses `release-next`, whose policy allows only branch nightly-next.

## 2

Above: `notary_pending: ${{ steps.notarize-nightly.outputs.submission_pending }}`

nightly-next is arm64 only, so its one matrix leg sets this; publish
waits for a later run when Apple had not accepted the build in time.

## 3

Above: `permissions:`

Sign and notarize on the same macOS 26 lane proven by stable releases.
actions:read lets the parallel artifact download resolve the blob URL.

## 4

Above: `strategy:`

One universal Xcode build feeds every variant: the thin variants are cut
from it with lipo, so each user downloads only their architecture.

## 5

Above: `- *hold-the-whole-mac`

First, before any checkout or secret: on an owned Mac this job holds the whole mini (glaeda's
exclusive class) or fails here (tests/test_ci_signing_owned_mac.py CLAIM_GATE).

## 6

Above: `submodules: false`

Main and RC signing do not need submodules. nightly-next's notice
check reads ghostty-next/build.zig.zon, so initialize that optional
submodule in the next step only for the cmux-next track.

## 7

Above: `- name: Checkout trusted signing controls`

This run's own signing controls: the claim below and, for an unsigned resume, the keychain controls.
Only scripts/ and the workflow are read from it, so it is sparse: a fresh full clone into this path took
about 3 min of the one signer on every sign (run 41948676510, 04:42:55-04:46:05Z).

## 8

Above: `- &x55`

macOS /bin/bash 3.2 exits 0 on a parse error in a script with an EXIT
trap (runs 39014131817, 39014922771). Parse every script this job can
run before any signing or notarization. An unsigned resume builds an
older tree: the checker and the workflow come from the signing control
(this run's commit), the scripts from the build tree.

## 9

Above: `NIGHTLY_SPARKLE_KEY: ${{ vars.NIGHTLY_SPARKLE_KEY }}`

scripts/ci/nightly-sparkle-key.sh picks the key per channel and
NIGHTLY_SPARKLE_KEY; unset keeps the shared key.

## 10

Above: `- &x60`

Read-only: can this ASC key register nightly-next's own App ID
(com.cmuxterm.app.next) and fetch its Developer ID profile? It reports
and never writes or fails the build.

## 11

Above: `- &x61`

The signing keychain exists only while this job signs. It is deleted
before any step runs code from the bundle, and created again for the
DMG signature. scripts/ci/signing-keychain.sh owns its lifetime.

## 12

Above: `- &x62`

Each channel has its own Developer ID profile:
APPLE_NIGHTLY_PROVISIONING_PROFILE_BASE64 / APPLE_RC_PROVISIONING_PROFILE_BASE64.

## 13

Above: `CMUX_NEXT_CEF_ON_DEMAND: ${{ needs.decide.outputs.track == 'nightly-next' && vars.CMUX_NEXT_CEF_ON_DEMAND == '1' && '1' `

Chromium on demand (plans/cmux-next/bundle-size-DESIGN.md 6.6): off
until the repository variable CMUX_NEXT_CEF_ON_DEMAND is 1.

## 14

Above: `CMUX_NEXT_LANGUAGE_PACKS: ${{ needs.decide.outputs.track == 'nightly-next' && vars.CMUX_NEXT_LANGUAGE_PACKS != '0' && '1`

Languages download on first use (CMUX-570): the non-English strings leave the app
for language packs, which publish-nightly uploads before the appcast. On for
nightly-next; the repository variable CMUX_NEXT_LANGUAGE_PACKS=0 turns it off.

## 15

Above: `CMUX_NEXT_TOOL_PACKS: ${{ needs.decide.outputs.track == 'nightly-next' && vars.CMUX_NEXT_LANGUAGE_PACKS != '0' && vars.C`

Tools few people use download on first use too (bin/cmux-mobile-host, the iPhone
host): its pack goes in the language packs' tools/ and is published with them. On
with language packs; the repository variable CMUX_NEXT_TOOL_PACKS=0 turns it off.

## 16

Above: `- name: Upload the Chromium runtime pack`

The runtime pack the app's pin names; publish-nightly uploads it
before the appcast.

## 17

Above: `- name: Upload the language packs`

The language packs the app's pin names (language-packs.py); publish-nightly uploads
them before the appcast.

## 18

Above: `- &x67`

The DMG needs the identity again. It runs no bundle code; notarize-nightly-dmg.sh deletes the keychain right after
the DMG signature, before static artifact verification.

## 19

Above: `CMUX_NOTARY_PENDING_ON_TIMEOUT: ${{ needs.decide.outputs.track == 'nightly-next' && needs.decide.outputs.should_publish `

Only a build that may publish hands a pending submission to a
later run; a notary test waits here and is never continued.

## 20

Above: `CMUX_DEFER_LAUNCH_SMOKES: "true"`

Runtime checks for the stapled app and final DMG run in
verify-signed-nightly, a job without secrets.

## 21

Above: `- name: Download the cmux-next source archive for recovery`

A later run publishes this build from the recovery artifact alone, so
it also carries the SSH daemon assets and, when published, the source
archive (their own artifacts expire after 3 days).

## 22

Above: `SPARKLE_CHANNEL: ${{ needs.decide.outputs.track == 'nightly-next' && (vars.NIGHTLY_NEXT_DEV_RING == 'on' && 'cmux-next-d`

cmux-next items carry a release-ring sparkle:channel, which only
cmux-next builds allow; every other build ignores them. With
NIGHTLY_NEXT_DEV_RING=on a new build starts on Dev (cmux-next-dev)
and moves to Nightly (cmux-next) on a canary pass
(scripts/ci/nightly_next_ring.py, nightly-next-verdict.yml).
