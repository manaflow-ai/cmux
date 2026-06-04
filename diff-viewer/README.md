# cmux Diff Viewer

This is the source-owned React app for `cmux open diff`.

Build it with:

```sh
./scripts/build-diff-viewer-app.sh
```

The build output is committed under `Resources/markdown-viewer/diff-viewer-app` because the macOS app serves local static files from its bundled resources. Keep source changes in this directory, then regenerate the bundled asset with the script above.

React Compiler is enabled in `vite.config.mjs` with the React 19 runtime target. Verify the compiled bundle guard with:

```sh
./scripts/check-diff-viewer-react-compiler.mjs
```

Large public stress samples are available through:

```sh
./scripts/open-diff-viewer-stress-samples.sh bun-rust
./scripts/open-diff-viewer-stress-samples.sh all
```

The sample opener sets `CMUX_DIFF_VIEWER_STREAM_REMOTE=1` by default so long DiffsHub and GitHub patches stream into the viewer instead of being downloaded by the CLI first.
