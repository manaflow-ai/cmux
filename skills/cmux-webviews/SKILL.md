---
name: cmux-webviews
description: "Build, bridge, and rendering rules for cmux WKWebView surfaces under webviews/ (Vite + React + Solid). Use when editing webviews/ source, the agent-session/kanban/diff renderers, the native bridge, or adding a new WKWebView-backed panel surface — and whenever a webview panel renders blank."
---

# cmux Webviews

The `webviews/` tree is a standalone Vite build that produces the JS/CSS chunks the macOS app (and iOS) load inside `WKWebView` panels (Kanban board, agent-session, diff). These rules keep the build, the native bridge, and the `file://` loading correct.

## Build discipline (the #1 footgun)

- **Rebuild with `./scripts/build-webviews-app.sh`, NEVER bare `bun run build`.** The Vite config has `emptyOutDir: true` and emits only `main.mjs` + `chunks/*.mjs`; the wrapper then writes the HTML shells (`agent-session.html`, `kanban.html`), inlines `marked.min.js` into the agent-session shell, and normalizes trailing whitespace. A bare `bun run build` wipes the output dir and deletes those `.html` files without regenerating them, leaving a broken bundle.
- Verify byte-for-byte with `./scripts/build-webviews-app.sh --check` (also a CI guard). Built assets land under `Resources/markdown-viewer/webviews-app/`.
- Typecheck and test the TS with `cd webviews && bun run typecheck` and `bun run test`.

## Surface dispatch

- `webviews/src/main.tsx` is the single entry: it detects the surface kind from DOM data attributes and **lazy-imports** the matching chunk (`kanban` / `agent-session` / `diff`). Keep new surfaces behind the same lazy-import dispatch so each chunk stays code-split.
- React and Solid renderers coexist (e.g. `agent-session/react/` and `agent-session/solid/`). The Solid renderer ships a single inlined bundle; React surfaces are code-split (this distinction matters for `file://`, below).

## Native bridge contract

- The bridge is built by `createNativeBridge` (`webviews/src/shared/nativeBridge.ts`) and installed synchronously at module eval as `window.cmuxKanbanBridge` / `window.cmuxAgentBridge`.
- JS → native: `window.webkit.messageHandlers.<handler>.postMessage(...)` (request/reply). native → JS: `window.cmux*Bridge.receive(event)` (push).
- State is **native-authoritative**: every reply and every pushed event replaces the whole model in the JS reducer (`kanban/shared/boardModel.ts`, `agent-session/shared/sessionModel.ts`). Never keep a divergent client-side copy — the native side is the single source of truth.
- For Kanban, theme is applied eagerly in `loadInitialBoard` because native applies theme before the bridge is registered; a late theme push is lost.

## file:// loading (silent-blank-panel trap)

- The native coordinator loads the chunk via `loadFileURL`. Over `file://` the document origin is `null`, so WebKit rejects every cross-origin module fetch — `main.mjs` never runs and no in-page error hook can fire. The symptom is a **silent blank panel**.
- Any coordinator that `loadFileURL`s a **code-split React** surface (dynamic `import()`) MUST set both `allowFileAccessFromFileURLs` (on `preferences`) and `allowUniversalAccessFromFileURLs` (on the configuration), via the shared `allowFileURLAccess(_:)` helper. The single inlined Solid bundle sidesteps this; a new React surface does not. See [`.github/review-bot-rules/wkwebview-file-url-access-keys.md`](../../.github/review-bot-rules/wkwebview-file-url-access-keys.md).

## Related

- The agent-session/Kanban-live native runtime (process store, fan-out, providers): `cmux-agent-session`.
- The Kanban engine and dispatch backends: `cmux-kanban`.
- Socket/focus rules for any new native command the bridge triggers: `cmux-socket-policy`.
