# Gallery matrix runner

This runner takes a JSON array of cases and captures each case in Chromium and WebKit at device scale 2. A case is one gallery stage: `frame.html` with the gallery's URL contract as its params (`webviews/src/gallery/env.ts`: entry, variant, locale, theme, colorScheme, fontFamily, fontSize, density, scale, width, height, reducedMotion, highContrast). Write a manifest from the gallery registry with `bun webviews/scripts/gallery/manifest.ts` (`--entries`, `--variants`, `--locales en|shipped|all`, `--themes default|pair|sample|all`, `--widths`, `--limit`). The runner waits for the stage's `data-gallery-ready` and renders in UTC. It serves a static gallery directory, writes PNGs and a framework-free `index.html`, and can compare matching PNGs in a baseline directory.

Install once from this directory:

```sh
bun install
bunx playwright install chromium webkit
```

Browsers never run on a developer laptop (coordinator rule, 2026-10-07): the runner renders only inside a Freestyle VM or on CI (`CMUX_GALLERY_IN_VM=1`). Locally, `--dry-run` lists the stage URLs of a manifest:

```sh
bun runner.ts --manifest manifest.example.json --gallery-dir ../../webviews/dist/gallery --dry-run
```

`path_or_url` can be a path relative to `--gallery-dir` or an absolute `http://`/`https://` URL. Every `params` entry is appended as a query parameter. `width` and `height` control the viewport; screenshots always use device scale 2. The page also receives the complete params object as `document.documentElement.dataset.galleryParams`.

Publish a run with `--publish-run <name>`: the output goes to `cmux-lawrence:~/cmux-gallery/matrix/<name>/`, served (tailnet only) at `https://cmux-lawrences-mac-mini.tail137216.ts.net:18796/matrix/<name>/` (also under `:18443/cmux-gallery/` for old links).

Compare against a baseline with `--baseline path/to/baselines --threshold 0.1`; the threshold is a percentage of differing pixels. The process exits non-zero when a present baseline exceeds it. The output index has filters for entry, variant, locale, theme and engine (read from params).

For a large matrix, create isolated Freestyle VMs and shard cases by index:

```sh
bun runner.ts --manifest manifest.json --gallery-dir dist/gallery --output-dir ../../.gallery-matrix-output \
  --freestyle-vms 2 --freestyle-snapshot freestyle/ubuntu-sm \
  --freestyle-key-file /Users/lawrence/.secrets/freestyle-cmux-next-dev-20261004.key
```

The Freestyle path installs the declared Bun dependencies and Playwright browsers in each VM, runs each shard in parallel, records every exact VM id in `.cmux-scratch/pane-protocol/gallery/freestyle-ledger.json`, and PAUSES only those recorded ids in a `finally` block (also on failure and signals). It never lists the account to decide what to pause or delete. A run refuses to start while the ledger holds ids an earlier run neither paused nor deleted; `--freestyle-cleanup` pauses exactly those. Each VM also pauses itself after 300 s of network idleness. The key is read from its file and only sent to the Freestyle API.

## Per-PR diff

`.github/workflows/gallery-pr.yml` runs on each PR to feat-cmux-next that touches the webviews. `webviews/scripts/gallery/touched.ts` picks the entries the change reaches: an entry's own file, anything its `covers` import, and every entry of a host whose stylesheet changed. A gallery or build-config change picks every entry. The job renders those entries x variants x both default themes x both engines on Linux at the merge-base and at the head, and at the head a second time.

`pr.ts` (with `compare.ts` and `report.ts`) compares each state and writes `diff/`:

- `index.html`: changed states first, each as a highlight overlay (changed regions boxed), a before/after slider and an onion skin; then new, removed, broken (the head stage did not mount) and nondeterministic states; unchanged states folded.
- `comment.md`: the sticky PR comment ("7 states changed: agent-pane.composer/streaming, ...") with before/after thumbnails of the changed regions.
- `summary.json`: the same summary for the team feed's PR card.

A state whose head render differs from a second head render is nondeterministic (a clock or fixture leak). It is listed apart and never counted as a PR change.

The render job runs the PR's code with no secrets. The publish job runs only the base branch's scripts: it rebuilds the comment from `outcomes.json`, puts the comment's thumbnails on the pr-media branch and updates the comment. The diff page, the PR's gallery and the matrix are in the run's `gallery-pr` artifact.

Tests:

```sh
bun test
```

For an isolated worktree run, set `CMUX_GALLERY_FREESTYLE_LEDGER` to an absolute path inside that worktree. Keep the same value for cleanup. The default shared ledger remains unchanged.

Publish an already captured matrix with `scripts/gallery-deploy.sh --matrix g5-pages-1 /path/to/output`. This uses the same publisher as `--publish-run` and launches no browser.
