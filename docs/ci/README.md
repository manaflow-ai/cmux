# CI in cmux (feat-cmux-next)

One page: what runs, where it is defined, and the one build entrypoint per product.

## What runs on a pull request

- `.github/workflows/cmux-next.yml` is the gate for a pull request into `feat-cmux-next`.
  `scripts/ci/cmux_next_route.py` reads the changed files and picks the tiers. The `cmux-next path routing`
  job's summary lists each tier and why it was picked. The tiers and labels are described in
  [cmux-next-tiers.md](cmux-next-tiers.md).
- Smaller workflows scoped by path (guards, media, shell integration, cloud, iOS) start only when their
  `paths:` match.
- Landing and the merge freeze: [landing.md](landing.md) and [merge-freeze.md](merge-freeze.md).

## One build entrypoint per product

| Product | Entrypoint |
|---|---|
| cmux NEXT macOS app (PR compile, Release compile, DEV app) | `cmux-next.yml` jobs `release-compile` and `cmux-scheme-compile`, run on the build fleet |
| cmux NEXT nightly and nightly-next | `nightly.yml` ([nightly-next-train.md](nightly-next-train.md)) |
| cmux-tui and the Rust workspaces | `cmux-next.yml` job `fast-tier-cargo` |
| Web bundles | `cmux-next.yml` job `web-bundles` |
| iOS | `test-ios.yml` and `ios-e2e.yml` ([ios-e2e.md](ios-e2e.md)) |

## Never cancelled

Nightly, dev, release and promote builds (`nightly.yml`, `request-cmux-next-dev-publish`, `request-nightly-next`)
are never cancelled.

## Keeping workflow files small

`tests/test_ci_workflow_file_size.py` keeps each workflow under 480,000 bytes, well below GitHub's 512,000-byte
limit. When a workflow grows past that:

- Long inline `run: |` blocks move verbatim to `scripts/ci/cmux-next-steps/<job>-<step>.sh`. Only steps in jobs
  that check out the run's own ref are moved. The step runs `bash -e <script>`, and tests read the moved step
  through `tests/cmux_next_step_text.py`.
- Long comments move word for word to `docs/ci/cmux-next-workflow-notes/` or `docs/ci/nightly-workflow-notes/`.
  Each leaves a `# Why: <file>` line in the workflow.
