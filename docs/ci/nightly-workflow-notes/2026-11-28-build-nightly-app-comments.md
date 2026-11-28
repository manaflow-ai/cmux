# `build-nightly-app`: the comments that were inline

Moved out of `.github/workflows/nightly.yml` on 2026-11-28 to keep the file under the size guard
(tests/test_ci_workflow_file_size.py). Each note names the line it sat above.

- Above `browser_data_proven: ${{ steps.browser-data-proof.outcome == 'success' && 'true' || '' }}`: The cx-f58x scan of the archived app passed here; prepare skips its own.
- Above `environment: ${{ github.ref == 'refs/heads/main' && 'ci-cache-writer' || github.ref == 'refs/heads/nightly-next' && 'art`: nightly-next: env artifacts holds CMUX_STORE_SIGNING_KEY (store packages, "Build the web bundles").
- Above `continue-on-error: true`: The lookup bounds itself (--timeout 240, then a miss): it never waits out a rate limit.
- Above `SKIP_REASON: ${{ format('{0}', vars.CI_NIGHTLY_NEXT_PRODUCT_REUSE) == '0' && 'vars.CI_NIGHTLY_NEXT_PRODUCT_REUSE is 0' |`: format(): an unset variable is null, and null == '0' is true.
- Above `- &x19`: Bundle acpmux only aliases bin/acpmux to bin/cmux; its input file is never copied.
- Above `GHOSTTY_ZIG_SOURCE: ghostty-next`: libghostty-vt (ghostty-vt-sys) builds from ghostty-next.
- Above `run: ZIG_KEEP_DIR="$HOME/Library/Caches/cmux-ci/zig" ./scripts/install-zig-ci.sh`: Reuses the Zig install kept on this Mac (install-zig-ci.sh ZIG_KEEP_DIR); downloads only on a cold Mac.
- Above `CMUX_SERVER_RELEASE_KEYS: ${{ vars.CMUX_SERVER_RELEASE_KEYS }}`: Compiled into `cmux` (decision SV-R1), as in cmux-tui-build-package.yml.
- Above `- &restore-bun-web-bundles`: Every restore here sets TOOLCHAIN_R2_ALL: the nightly Macs are not Freestyle runners, and github.com refuses setup-bun's anonymous download from them (403, runs 45765712386 and 45756842046).
- Above `- &x28`: setup-node can succeed with no node on PATH (scripts/ci/ensure-setup-node.sh).
- Above `AWS_ACCESS_KEY_ID: *cache-r2-key-id`: Only an R2 save sees the bucket credentials.
- Above `AWS_ACCESS_KEY_ID: *cache-r2-key-id`: Only an R2 save sees the bucket credentials.
- Above `- name: Upload dSYMs to Sentry`: nightly-next uploads in sentry-dsyms-nightly, off this job's critical path.
- Above `compression-level: 0`: The tar.gz is already compressed; avoid wasting runner CPU on outer deflate.
- Above `env: *artifact-upload-concurrency`: 221 MB in 34-108 s at the default 5 blocks, before the job can end.
- Above `overwrite: true`: A failed-jobs re-run recompiles under the same build number; the newest symbols win.
- Above `- &x49`: The fast build's Rust client dSYMs, for sentry-dsyms-nightly.
- Above `retention-days: 2`: As long as the archive it names.
