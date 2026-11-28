# nightly.yml build-nightly-app: comments moved out of the workflow

Moved verbatim from `.github/workflows/nightly.yml` to keep it under its size budget (tests/test_ci_workflow_file_size.py).
Each block names the line it stood above. New prose for this job goes here, not in the workflow.

Above `concurrency:`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-build-nightly-app-3.md

Above `browser_data_proven: ${{ steps.browser-data-proof.outcome == 'success' && 'true' || '' }}`:

    # The cx-f58x scan of the archived app passed here; prepare skips its own.

Above `if: "!cancelled() && needs.decide.result == 'success' && needs.resolve-nightly-cmux-tui-client.resul`:

    # Why: docs/ci/nightly-workflow-notes.md#note-38

Above `runs-on: ${{ github.repository_owner != 'manaflow-ai' && 'macos-26' || vars.CI_NIGHTLY_MINI != '' &&`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-27-builder-cache-context.md
    # Why: docs/ci/nightly-workflow-notes/2026-11-26-build-nightly-app-2.md

Above `environment: ${{ github.ref == 'refs/heads/main' && 'ci-cache-writer' || github.ref == 'refs/heads/n`:

    # nightly-next: env artifacts holds CMUX_STORE_SIGNING_KEY (store packages, "Build the web bundles").

Above `timeout-minutes: ${{ vars.CI_NIGHTLY_MINI != '' && 270 || 150 }}`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-build-nightly-app.md

Above `NIGHTLY_PUBLISH_PEERS: resolve-nightly-ghostty-cli-helper build-nightly-ghostty-cli-helper build-nig`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-build-nightly-app-4.md

Above `- name: Mint the glaeda read token for the unsigned restore`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-build-nightly-app-mint-the-glaeda-read-token-for-the-unsigne.md

Above `CMUX_ARTIFACT_RETRY_BUDGET_SECONDS: "1800"`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-build-nightly-app-1.md

Above `- name: Checkout build ref (warm nightly-next builder)`:

    # Why: docs/ci/nightly-workflow-notes.md#note-20, note-54

Above `timeout-minutes: 15`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-27-build-nightly-app-5.md

Above `- &x11`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-build-nightly-app-retain-unsigned-resume-provenance-retry-3.md

Above `if: inputs.nightly_next_unsigned_run == ''`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-build-nightly-app-2.md

Above `- name: Look up the nightly app compiled on the same inputs`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-build-nightly-app-3.md

Above `continue-on-error: true`:

    # The lookup bounds itself (--timeout 240, then a miss): it never waits out a rate limit.

Above `SKIP_REASON: ${{ format('{0}', vars.CI_NIGHTLY_NEXT_PRODUCT_REUSE) == '0' && 'vars.CI_NIGHTLY_NEXT_P`:

    # format(): an unset variable is null, and null == '0' is true.

Above `if: (inputs.nightly_next_unsigned_run == '' && (needs.decide.outputs.track != 'nightly-next' || step`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-build-nightly-app-look-up-the-nightly-app-compiled-on-the-sa-2.md

Above `- name: Restore the acpmux and OptChat Chief dependency builds (cmux-next)`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-build-nightly-app-4.md

Above `add-rust-environment-hash-key: false`:

    # Why: docs/ci/cmux-next-workflow-notes.md#note-210 (pool runners keep different leftover toolchains)

Above `- &x19`:

    # Bundle acpmux only aliases bin/acpmux to bin/cmux; its input file is never copied.

Above `- name: Install Zig for fast cmux-tui client`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-build-nightly-app-5.md

Above `GHOSTTY_ZIG_SOURCE: ghostty-next`:

    # libghostty-vt (ghostty-vt-sys) builds from ghostty-next.

Above `ZIG_FORCE_LOCAL_INSTALL: "1"`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-build-nightly-app-install-zig-for-fast-cmux-tui-client-2.md

Above `run: ZIG_KEEP_DIR="$HOME/Library/Caches/cmux-ci/zig" ./scripts/install-zig-ci.sh`:

    # Reuses the Zig install kept on this Mac (install-zig-ci.sh ZIG_KEEP_DIR); downloads only on a cold Mac.

Above `CMUX_SERVER_RELEASE_KEYS: ${{ vars.CMUX_SERVER_RELEASE_KEYS }}`:

    # Compiled into `cmux` (decision SV-R1), as in cmux-tui-build-package.yml.

Above `CARGO_PROFILE_RELEASE_DEBUG: line-tables-only`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-build-nightly-app-6.md

Above `- name: Sanitize Swift package cache`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-build-nightly-app-sanitize-swift-package-cache.md

Above `- &restore-bun-web-bundles`:

    # Why: docs/ci/nightly-workflow-notes.md#note-13
    # Every restore here sets TOOLCHAIN_R2_ALL: the nightly Macs are not Freestyle runners, and github.com refuses
    # setup-bun's anonymous download from them (403, runs 45765712386 and 45756842046).

Above `- &restore-node-web-bundles`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-build-nightly-app-restore-pinned-node-24-22-1-from-the-ci-ca-2.md

Above `- &x28`:

    # setup-node can succeed with no node on PATH (scripts/ci/ensure-setup-node.sh).

Above `- &x29`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-build-nightly-app-restore-pinned-node-24-22-1-from-the-ci-ca.md

Above `- name: Download the web bundles built beside the app (cmux-next)`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-build-nightly-app-download-the-web-bundles-built-beside-the-.md

Above `- name: Stop when the run can no longer publish (before the compile)`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-build-nightly-app-7.md

Above `- &x37`:

    # Why: docs/ci/nightly-workflow-notes.md#note-10

Above `AWS_ACCESS_KEY_ID: &cache-r2-key-id ${{ (inputs.cache_backend != 'default' && inputs.cache_backend |`:

    # Only an R2 save sees the bucket credentials.

Above `AWS_ACCESS_KEY_ID: *cache-r2-key-id`:

    # Only an R2 save sees the bucket credentials.

Above `GH_TOKEN_SPARES: ${{ secrets.CI_POOL_TOKEN_1 }} ${{ secrets.CI_POOL_TOKEN_2 }}`:

    # RATE_LIMIT_MOVES_TO_A_SPARE (pin-cmux-tui.sh github_get): the tree wait's runs reads move
    # to the CI pool's tokens when the installation's hour is spent (nightly 46095639816).

Above `- name: Upload dSYMs to Sentry`:

    # nightly-next uploads in sentry-dsyms-nightly, off this job's critical path.

Above `- name: Stop when the run can no longer publish (before the upload)`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-build-nightly-app-8.md

Above `- name: Upload unsigned nightly app`:

    # Why: docs/ci/nightly-workflow-notes.md#note-6

Above `compression-level: 0`:

    # The tar.gz is already compressed; avoid wasting runner CPU on outer deflate.

Above `- &x48`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-build-nightly-app-9.md

Above `env: *artifact-upload-concurrency`:

    # 221 MB in 34-108 s at the default 5 blocks, before the job can end.

Above `overwrite: true`:

    # A failed-jobs re-run recompiles under the same build number; the newest symbols win.

Above `- &x49`:

    # The fast build's Rust client dSYMs, for sentry-dsyms-nightly.

Above `- name: Pack the nightly app for reuse`:

    # Why: docs/ci/nightly-workflow-notes/2026-11-26-build-nightly-app-pack-the-nightly-app-for-reuse.md

Above `retention-days: 2`:

    # As long as the archive it names.
