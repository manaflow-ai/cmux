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

## Runtime status

The engine-neutral runtime lives in `Resources/browser-repl/` and loads in the
order the app's `BrowserReplRuntimeBundle` uses: `vendor/acorn.js`,
`vendor/playwright-locator-utils.js`, `runtime-core.js`, `dialect-aside.js`,
`dialect-chatgpt.js`, `repl-host.js` for the REPL context, and
`vendor/playwright-injected.js` plus `page-agent.js` for each frame's agent
world. `repl-host.js` adapts the app's `__cmuxNative` object and defines
`__cmuxReplEval`. Both dialects share one session.

`tests/browser-parity/lib/dev-driver.mjs` implements the driver protocol on
Playwright WebKit, and `run.mjs --backend cmux-dev` runs scenarios through the
same scripts in Node, with no app build:

```sh
node tests/browser-parity/run.mjs check --backend cmux-dev --dialect aside
node tests/browser-parity/run.mjs ax        # tab.ax text vs ChatGPT's own renderer
node --test tests/browser-parity/unit/*.test.mjs
```

Results on 2026-09-29:

- Aside dialect: 11 of 13 scenarios match their goldens exactly. `04-input`
  and `05-frames` fail only on the golden disputes below.
- `tab.ax`: 12 of 12 cases match ChatGPT's renderer byte for byte (all
  fixture pages, the 02 action sequence, revision diffs, the no-change
  message, focus, and a prompt dialog).
- ChatGPT scenarios run end to end; there are no ChatGPT goldens yet.

Golden disputes (goldens left unchanged):

- `04-input` `scrolled` expects `false`. The Playwright reference reads
  `scrollTop` right after `mouse.wheel()`, while Chrome still scrolls
  asynchronously. WebKit scrolls before the read, so cmux reports `true`,
  which is what the scenario means to test.
- `05-frames` `full` and `after-clicks` use Aside's registration-order frame
  prefixes (`f2` for the first iframe); cmux numbers frames in DOM order, as
  decided above. The URL in the title line also keeps a raw peer port
  (`%3A56559`) that `normalize.mjs` cannot rewrite, because `\b` does not
  match between `A` and the digits. With the peer port pinned and `f1`/`f2`
  swapped, both values match exactly.
- `scenarios/chatgpt/02-ax-actions.js` looks for `/textbox Email/`,
  `/checkbox Accept terms/` and `/textbox Bio/`. ChatGPT prints `text field
  (settable) Email` and `checkbox (settable, integer) Description: Accept
  terms`, so the scenario throws on the real reference too. With matching
  regexes the sequence runs and its AX text matches the reference.

Decisions made in the runtime:

- Click focus follows Chromium. WebKit on macOS does not focus buttons and
  links on mouse click; the runtime focuses the clicked control between
  mousedown and mouseup when the page did not move focus itself. Goldens 03
  and 05 (`[focused]`) depend on it. The Swift driver must not add its own
  emulation.
- Pointer actions check the hit target again after moving the pointer and
  retry, as Playwright's hit-target interceptor does (a `:hover` menu that
  collapses on move shifts the target).
- `fs`, uploads and `download.saveAs` stay inside the session directory;
  completed downloads are readable. ChatGPT scenario 06 uploads files from
  `os.tmpdir()` and fails under this rule.
- `import()` in a cell calls the host's optional `importModule`. The app has
  none, so Node modules fail with a clear error; the dev backend allows them.
- The page agent builds ChatGPT's tree from DOM and ARIA with Chromium's
  role strings and quirks (list markers, redundant checkbox labels, select
  popups, disclosure triangles, iframe bodies). Roles and names come from
  the DOM, not WebKit's accessibility tree, so pages beyond the fixtures can
  still differ from Chromium; `run.mjs ax` is the regression check.
