# cmux Diff Viewer

This is the source-owned React app for `cmux open diff`.

Build it with:

```sh
./scripts/build-diff-viewer-app.sh
```

The build output is committed under `Resources/markdown-viewer/diff-viewer-app` because the macOS app serves local static files from its bundled resources. Keep source changes in this directory, then regenerate the bundled asset with the script above.
