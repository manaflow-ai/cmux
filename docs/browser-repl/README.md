# cmux browser REPL parity

Living design doc for `cmux browser repl`: an agent REPL for cmux browser panes
with full parity with the Aside CLI (`aside repl`) and ChatGPT for Chrome (the
Codex `browser`/`chrome` plugins). Aside's `exec` agent delegation is out of
scope; only browser operation is in scope.

## Target

One REPL, two dialects, one engine driver:

| Dialect | Globals | Reference |
| --- | --- | --- |
| `aside` | `page`, `tabs`, `listBrowserTabs`, `attachBrowserTab`, `attachActiveBrowserTab`, `getTabByTargetId`, `openTab`, `closeTab`, `snapshot`, `annotatedScreenshot`, `fetch`, `fs`, `path`, `Buffer`, `sleep`, `display`, `pwd` | Aside CLI 1.26.916, `aside guide repl`, [aside-api-surface.txt](../../tests/browser-parity/reference/aside-api-surface.txt) |
| `chatgpt` | `agent` (`agent.browsers`, `Browser`, `Tab`, `tab.ax`, `tab.playwright`, `tab.cua`, `tab.dom_cua`, `tab.clipboard`, `tab.dev`, `tab.content`, capabilities) | ChatGPT for Chrome 26.917.71314, [chatgpt-api-surface.txt](../../tests/browser-parity/reference/chatgpt-api-surface.txt) (152 members) |

Both dialects run in the same session, so `snapshot(page)` and
`tab.ax.write()` can address the same cmux browser surface.

Representations:

- `snapshot()` reproduces Aside's text exactly: title header, ARIA roles,
  `[ref=eN]` on actionable nodes, `fN` prefixes for frames, unified diff. Rules:
  [aside-snapshot-spec.md](aside-snapshot-spec.md).
- `tab.ax` reproduces ChatGPT's accessibility text: macOS AX role names
  (`AXWebArea`, `container`, `text field`), preorder IDs that persist by parent
  and sibling position, and its revision diff. Rules:
  [chatgpt-ax-spec.md](chatgpt-ax-spec.md). `tests/browser-parity/lib/chatgpt-ax-reference.mjs`
  renders any fixture with ChatGPT's own renderer (from the installed plugin,
  not copied) for offline goldens.

## Choosing between the references

Where Aside and ChatGPT disagree on semantics, or a reference is broken, the
target is the better behavior, recorded per test value in
`tests/browser-parity/goldens/<dialect>/<scenario>.choices.json` with a reason.
The tie-breaker for the aside dialect is real Playwright (its API is Aside's
model). Found so far:

| Area | Aside | Playwright / ChatGPT | Target |
| --- | --- | --- | --- |
| Checkbox click, drag | synthetic DOM events (`isTrusted=false`) | trusted input | trusted input |
| Hover, right click, mouse wheel | no effect | real input | real input |
| `page.on("dialog")` | never fires; dialogs auto-accepted | handler receives dialog; unhandled dialogs dismissed | Playwright |
| `waitForURL(RegExp)` | throws | supported | supported |
| `getByRole` into shadow DOM, `{ level }` | throws | supported | supported |
| `page.waitForEvent("popup")` | times out | supported | supported |
| Snapshot format | compact, refs only on actionable nodes | Playwright AI snapshot has refs on every node and more `generic` noise | Aside |

## Architecture

```
agent ── cmux browser repl ──▶ control socket ──▶ ReplSession (JavaScriptCore, one per session)
                                                   │ aside + chatgpt dialect runtimes (JS)
                                                   ▼
                                             BrowserDriver protocol
                                              │                 │
                                     WebKit driver        Chromium driver
                                (WKWebView, native)     (CDP passthrough, when the
                                                         Chromium engine lands)
```

- **REPL host.** Sessions run in JavaScriptCore inside the app, one
  `JSContext` per session on its own thread. The CLI sends code over the socket
  and streams `console.log` output back. Top-level `const`/`let` persist across
  calls, as in Aside, by rewriting top-level declarations before evaluation.
  JavaScriptCore gives the same sandbox Aside documents (no `import`/`require`)
  and needs no bundled Node. Open decision: ChatGPT's REPL is full Node; scripts
  that use Node modules beyond `fs`/`path`/`Buffer` will not run.
- **Page script.** One script in an isolated `WKContentWorld`, injected in every
  frame including cross-origin frames. It builds both snapshot formats, owns the
  ref table, and resolves locators. Locator semantics (`getByRole`, `getByText`,
  `filter`, `nth`, frame locators) use Playwright's injected script (Apache-2.0,
  runs on WebKit), so they match Playwright rather than an approximation.
- **Input.** Clicks, hover, drag, wheel and keys are native `NSEvent`s delivered
  to the `WKWebView`, so pages see `isTrusted=true`. The current synthetic JS
  click path is removed from automation.
- **Engine hooks.** Dialogs, file choosers and popups come from `WKUIDelegate`;
  downloads from `WKDownloadDelegate`; PDF from `createPDF`; screenshots from
  `takeSnapshot`; request and response events from WebKit's resource load
  delegate.

## Engine limits

WebKit cannot provide Chrome DevTools Protocol. These ChatGPT members need the
Chromium driver: `tab.capabilities.cdp` (raw CDP) and network interception.
ChatGPT disables both by default in its own `iab` and `extension` backends. The
WebKit driver reports them as unsupported capabilities; the Chromium driver
passes them through.

## Test suite

`tests/browser-parity/`: fixture site on two origins, scenarios per dialect,
goldens recorded from the references, and a runner. See
[its README](../../tests/browser-parity/README.md).

## Status

- [x] Reference API surfaces captured
- [x] Fixture site, runner, Aside and Playwright goldens (13 scenarios)
- [ ] ChatGPT goldens (needs a Codex login with a ChatGPT account)
- [x] Snapshot and AX format specs
- [ ] Page script (both formats) passing format goldens on WebKit
- [ ] Native input, dialogs, file chooser, downloads, popups, PDF
- [ ] JavaScriptCore REPL host and `cmux browser repl`
- [ ] All scenarios pass on a tagged build
