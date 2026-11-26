# cmux Webviews

This is the source-owned React bundle for embedded cmux webviews. It currently ships the `cmux diff` viewer and is structured to host more React-backed webviews.

Build it with:

```sh
./scripts/build-webviews-app.sh
```

The build output is committed under `Resources/markdown-viewer/webviews-app` because the macOS app serves local static files from its bundled resources. Keep source changes in this directory, then regenerate the bundled asset with the script above.

React Compiler is enabled in `vite.config.mjs` with the React 19 runtime target. Verify the compiled bundle guard with:

```sh
./scripts/check-webviews-react-compiler.mjs
```

Large public stress samples are available through:

```sh
./scripts/open-diff-viewer-stress-samples.sh bun-rust
./scripts/open-diff-viewer-stress-samples.sh all
```

The sample opener caches local clones under `/tmp/cmux-diff-viewer-stress`, checks out the sample refs, then runs `cmux diff --base <ref>` from inside the repository so the stress path matches normal local git diffs.
