# Gallery matrix runner

This runner takes a JSON array of cases and captures each case in Chromium and WebKit at device scale 2. It serves a static gallery directory, writes PNGs and a framework-free `index.html`, and can compare matching PNGs in a baseline directory.

Install once from this directory:

```sh
bun install
bunx playwright install chromium webkit
```

Run a local matrix:

```sh
bun runner.ts --manifest manifest.example.json --gallery-dir ../../webviews/dist/gallery --output-dir /tmp/gallery-matrix
```

`path_or_url` can be a path relative to `--gallery-dir` or an absolute `http://`/`https://` URL. Every `params` entry is appended as a query parameter. `width` and `height` control the viewport; screenshots always use device scale 2. The page also receives the complete params object as `document.documentElement.dataset.galleryParams`.

Compare against a baseline with `--baseline path/to/baselines --threshold 0.1`; the threshold is a percentage of differing pixels. The process exits non-zero when a present baseline exceeds it. The output index has filters for component, state, locale, theme and engine (component/state are read from params).

For a large matrix, create isolated Freestyle VMs and shard cases by index:

```sh
bun runner.ts --manifest manifest.json --gallery-dir dist/gallery --output-dir /tmp/gallery-matrix \
  --freestyle-vms 2 --freestyle-snapshot freestyle/ubuntu-sm \
  --freestyle-key-file /Users/lawrence/.secrets/freestyle-cmux-next-dev-20261004.key
```

The Freestyle path installs the declared Bun dependencies and Playwright browsers in each VM, runs each shard in parallel, records every exact VM id in `.cmux-scratch/pane-protocol/gallery/freestyle-ledger.json`, and deletes only those recorded ids in a `finally` block (including signal handling). It never lists the account to decide what to delete.

Tests:

```sh
bun test
```
