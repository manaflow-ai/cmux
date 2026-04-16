# cmux Monaco bundle

Vite-built Monaco editor surface shipped inside the macOS app. The WKWebView in
`Sources/Panels/MonacoEditorView.swift` loads `dist/index.html` via the
`cmux-monaco://` URL scheme handler.

`dist/` is checked in so CI doesn't need Node. Rebuild after editing anything
under `src/` or bumping the `monaco-editor` dependency:

```
./scripts/build-monaco.sh
```

That runs `npm ci && npm run build` and overwrites `dist/`. Commit the
regenerated files together with your source changes.

## Layout

- `src/main.ts` — bootstraps Monaco, wires message bridges, manages view state
- `src/bridge.ts` — typed JS↔Swift protocol
- `src/theme.ts` — Ghostty-derived theme override layered on top of `vs`/`vs-dark`
- `index.html` — host page with CSP for `cmux-monaco://`
- `dist/` — build output, committed

## Message protocol

JS → Swift (`window.webkit.messageHandlers.cmux.postMessage`):

| type           | payload                                              |
|----------------|------------------------------------------------------|
| `ready`        | editor mounted, asks Swift for initial state         |
| `changed`      | user edited buffer: `value`, `cursor`, `versionId`   |
| `saveRequested`| user triggered ⌘S inside Monaco                     |
| `viewState`    | debounced snapshot: cursor + scrollTopFraction + JSON-encoded `ICodeEditorViewState` |

Swift → JS (`window.cmuxMonaco.apply(...)`):

- `setText` — replace buffer, optionally keep viewState
- `setCursor` — position + selection length
- `restoreViewState` — preferred restore path on tab mount
- `setTheme` — `isDark`, `backgroundHex`, `foregroundHex`
- `setLanguage` — Monaco language id
- `focus` — make the editor first responder

See `src/bridge.ts` for the exact shapes.
