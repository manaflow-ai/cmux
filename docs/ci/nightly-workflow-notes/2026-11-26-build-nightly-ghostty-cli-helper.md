# nightly.yml `build-nightly-ghostty-cli-helper`: notes moved out of the workflow

Moved from `.github/workflows/nightly.yml` to keep it under GitHub's 500 KB workflow file limit
(tests/test_ci_workflow_file_size.py). Each section's number is the `#N` in the job's `# Why:` line.

## 1

Above: `- &select-xcode-sdk-unless-resumed`

*select-xcode-sdk with the `if:` of this job's build steps (a resumed run builds nothing).
Zig only: no Xcode is selected here, so this is the SDK of the host's default Xcode.

## 2

Above: `- &x2`

The helper and the classic ghostty tree take the default Zig (PATH,
CMUX_ZIG); the source archive's libghostty-vt tree (ghostty-next,
0.17.0) takes CMUX_VT_ZIG, a local install beside it.

## 3

Above: `- name: Strip the Ghostty CLI helper`

The strip-release-bundle.sh pass that prepare-nightly-variant ran on
the injected helper (helpers keep their global symbols). That job is on
Linux now, where only Apple's strip gives these bytes; a fast build's
prepare never stripped it.

## 4

Above: `overwrite: true`

A re-run of pick-nightly-build-runner re-runs this job after a success
(owned_pool_rescue.repick_job()); its second upload replaces the first.

## 5

Above: `- name: Upload cmux-next license trees`

Signing only embeds the license trees. Keep that handoff separate from
the optional source offer so each signing leg does not download the
complete source archive just to copy a few notices into the app.

## 6

Above: `overwrite: true`

A re-run of pick-nightly-build-runner re-runs this job after a success
(owned_pool_rescue.repick_job()); its second upload replaces the first.
