# nightly.yml `prepare-nightly-variant-primary`: notes moved out of the workflow

Moved from `.github/workflows/nightly.yml` to keep it under GitHub's 500 KB workflow file limit
(tests/test_ci_workflow_file_size.py). Each section's number is the `#N` in the job's `# Why:` line.

## 1

Above: `needs: [decide, build-nightly-ghostty-cli-helper, build-nightly-app, build-nightly-remote-daemon, resolve-nightly-cmux-t`

No environment and no secrets. It runs no code from the bundle; the
theme picker regression and the sidecar handshake run on the signed app
in verify-signed-nightly. build-sign-notarize-nightly signs exactly the
app it uploads and runs no bundle code itself (#21024).

## 2

Above: `submodules: false`

Main and RC signing do not need submodules. nightly-next's notice
check reads ghostty-next/build.zig.zon, so initialize that optional
submodule in the next step only for the cmux-next track.

## 3

Above: `- &older-tree-step-scripts`

A build tree older than this workflow lacks the step scripts it added (an unsigned
resume of an older run): check out only those, from the workflow commit.

## 4

Above: `- &download-nightly-ghostty-license-trees`

Blocking, like the step that builds it: a nightly-next app always
ships the Ghostty license tree. This is a small artifact containing
only the trees, rather than the complete source offer archive.

## 5

Above: `if: ${{ (env.PREPARE_FALLBACK != 'true' || steps.reuse.outputs.exists != 'true') && (matrix.variant != 'universal') }}`

The fast build is already compiled arm64, but the downloaded cmux-tui
client can still be universal. Thin every non-universal artifact before
signing so the architecture gate remains meaningful. The Chromium
engine artifact is arm64 only: an x86_64 variant drops it first and
reports the browser unavailable.

## 6

Above: `- &upload-prepared-app-for-signin`

Signing waits on this job's end. On a dedicated nightly Mac the default 5 blocks
at a time took 65-156 s (median 85 s, runs 41455121554-41488515134), against
3 s on Blacksmith Linux; 32 at a time, as the unsigned-app upload since #32343.
