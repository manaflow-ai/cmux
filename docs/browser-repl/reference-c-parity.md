# Reference C parity

Every agent-facing capability of reference C, an open-source browser agent,
mapped to `cmux browser repl`. Reference C runs its own model loop over a
numbered DOM list and a Python tool registry. The REPL is driven by an outside
agent in JavaScript, so a reference C tool becomes a Playwright call, a ref, or
one of the additions in `Resources/browser-repl/agent-tools.js`. Nothing in
cmux calls a model. Reference C's model-backed tools (extraction with a
question, finding an element from a description) map to deterministic reads
the calling agent reasons over.

Verdicts: **same** (the capability exists with equivalent behavior),
**better** (it exists and closes a gap reference C leaves, stated in the
row), **skipped** (not built, with the reason). Proof tests are in
[tests/browser-parity](../../tests/browser-parity/README.md): `NN-name` is a
scenario (`key` its golden value), `unit:` a `node --test` file.

## Tools

| Reference C | cmux | Proof | Verdict |
| --- | --- | --- | --- |
| Navigate to a URL, optionally in a new tab | `page.goto(url)`, `tabs.open(url)` | 12-navigation, 13-tabs | same |
| Go back | `page.goBack()` | 12-navigation | same |
| Web search with a chosen engine (opens a results page) | `search(query, { engine: "duckduckgo" \| "bing" \| "google", limit })` returns `[{ title, url, snippet }]`; Google goes through `sites.googleSearch` | 32-agent-tools `search-duckduckgo`, `search-bing` | better: structured results instead of a page to read; a CAPTCHA page is an error, not an empty result |
| Click an element by index, or click at coordinates | `page.locator("e5").click()`, `page.mouse.click(x, y)` | 17-refs, 04-actions-diff, 22-api-surface `mouse-down-up` | better: refs never renumber; real, trusted input with Playwright actionability |
| Detect a new tab opened by a click | `page.on("popup")`, `waitForEvent("popup")` | 13-tabs | same |
| Type text into an element, optionally clearing it first | `locator.fill(text)`, `locator.pressSequentially(text)` | 05-input | same |
| Upload a file through an element | `locator.setInputFiles(path)`, `page.fileChooser()` | 10-files | same |
| Switch to a tab, close a tab | `tabs.use(id)`, `page.close()` | 13-tabs | same |
| Send keys and shortcuts | `page.keyboard.press("Control+o")` | 05-input, 22-api-surface `keyboard-primitives` | same |
| Scroll to a text | `page.scrollToText(text)` returns the element's ref | 32-agent-tools `scroll-to-text` | same |
| Scroll the page or an element up or down by pages | `page.scroll({ pages, target })` (native wheel; negative pages scroll up), `page.scrollInfo(target?)` | 32-agent-tools `scroll-page`, `scroll-element` | same |
| List a dropdown's options | `page.dropdownOptions(ref)`: `<select>` options, or an open ARIA combobox, listbox or menu with a ref per option; the snapshot also prints `[options: …]` | 32-agent-tools `dropdown-select`, `dropdown-aria`, 01-snapshot | same |
| Select a dropdown option by its text | `locator.selectOption(label)`; an ARIA option's ref from `dropdownOptions` is clicked | 04-actions-diff, 32-agent-tools `dropdown-aria-ref-clicks` | same |
| Extract data for a question, optionally to a schema (page to Markdown, then a model) | `page.markdown({ main, links, images, start, maxChars })`; `page.extract({ $: ".item", name: "h3", url: "a@href" })` for structured data by selectors | 32-agent-tools `markdown*`, `extract*`; 33-markdown-corpus; unit: agent-tools `markdown: chunks…` | better: no model call, deterministic; iframes (cross-origin) and closed shadow roots in place; on the nine-page corpus every text link Chrome shows is kept and no text Chrome hides appears; a cut repeats the table header and names the next `start` |
| Continue extraction from a character offset, skip already collected items | `page.markdown({ start, maxChars })`; deduplication is the caller's code | unit: agent-tools `markdown: chunks…` | same |
| Search page text by pattern or regular expression, within a CSS scope | `page.searchText(pattern, { regex, caseSensitive, context, scope, limit })` → `{ total, matches: [{ match, context, ref }] }` | 32-agent-tools `search-text*` | better: each match carries a ref that works as a locator |
| Find elements by CSS selector and read their attributes | `page.locator(sel).evaluateAll(...)`, `page.extract([sel + "@attr"])` | 15-locators, 32-agent-tools `extract` | same |
| Screenshot to a file | `screenshot({ path })`, `page.screenshot()` | 14-screenshots | same |
| Save the page as a PDF (paper format, orientation, and more) | `page.pdf({ format, landscape, printBackground, margin, path })` | 14-screenshots | same (header and footer templates: WebKit's print has none) |
| Run JavaScript in the page, with automatic repair of broken quotes | `page.evaluate(fn, arg)` | 05-input, 15-locators | same: the agent writes real JavaScript, so there is nothing to repair |
| Wait some seconds | `sleep(ms)`, `page.waitForTimeout(ms)`, Playwright auto-waits | 09-dialogs-held | same |
| Write, read and replace files | `fs.writeFileSync`, `fs.readFileSync`, `fs.appendFileSync` (sandboxed to the cwd and temp) | 21-fs | same |
| Write a PDF or Word document from Markdown | none | | skipped: a converter is outside browser operation; the agent's own tools write documents |
| Finish the task with a result, a success flag and files, optionally as structured output | the REPL value the agent returns | | skipped: an agent-loop terminator; the outside agent ends its own task |

## DOM representation

The format studies and the representation comparison live in the private repository `manaflow-ai/cmux-browser-parity-private`.

| Reference C | cmux | Proof | Verdict |
| --- | --- | --- | --- |
| Interactive elements listed with a number | snapshot refs `[ref=e12]` usable as locators | 01-snapshot, 17-refs | better: a ref is bound to its node and never reused; stale refs fail with a reason |
| Markers on elements that are new since the last step | the snapshot prints its diff against the previous one | 04-actions-diff, 18-print | better: added, removed and changed lines with context |
| Cross-origin iframes, with a count and depth limit | every frame inlined with `fN` ref prefixes, at any depth | 06-frames, 25-nested-frames, 31-frame-calls | same |
| Shadow DOM | open and closed shadow roots pierced | 07-shadow, 26-closed-shadow | better: closed roots too |
| Page and element scroll position (pages above and below) | `page.scrollInfo(target?)`; snapshot `{ viewport: true }` notes what is off screen; `[scrollable]` marks scroll regions | 32-agent-tools `scroll-page`, 28-compact | same |
| Paint-order filtering of covered elements | not filtered; a click on a covered element fails with Playwright's hit-target check naming the cover | 15-locators | skipped: removing covered elements hides controls behind transient overlays; acting reports occlusion exactly |
| Overlay that highlights elements, and highlight of the element acted on | `page.highlight(targets?)`, `locator.highlight()`, `page.hideHighlight()`; `screenshot({ annotate: true })` | 32-agent-tools `highlight`, 14-screenshots | same |
| Choose which element attributes the DOM list shows | snapshot `{ urls: true }`, `page.extract` with `@attr`, locators | 01-snapshot, 32-agent-tools `extract` | same |

## Browser session and profile

| Reference C | cmux | Proof | Verdict |
| --- | --- | --- | --- |
| Allowed and prohibited domains, blocking IP addresses | `session.allowedDomains([...], { lock })`, `session.prohibitedDomains([...])`, `session.blockIPAddresses(true)`, `session.blockedNavigations()` | 32-agent-tools `policy-*`; unit: agent-tools `domain patterns`, `hosts compare…` | better: the policy is kept and enforced by the native session and driver, outside the JavaScript context agent code runs in, so `{ lock: true }` holds even against agent code that replaces runtime objects or calls the driver directly. It covers navigations and new tabs, the REPL's `fetch` (every redirect hop), `tabs.content` and site tools, and blocks subresources (images, scripts, styles, fonts, media, XHR and fetch, WebSockets, iframes) through a WebKit content rule list built natively, where reference C filters navigations only (32-agent-tools `policy-subresources`). Hosts compare without case, trailing dots or Unicode spelling (Punycode); `blockIPAddresses` blocks every numeric spelling of an address (`0x7f.1`, `2130706433`, `0177.0.0.1`, `[0:0:0:0:0:0:0:1]`), also in subresources, since WebKit canonicalizes a URL's host before the content rules match it (`BrowserReplContentRuleIPTests` loads each spelling against a loopback server); natively an address in a pattern or URL compares by its canonical spelling (`2130706433` and `127.1` are `127.0.0.1`, `[0:0::1]` is `[::1]`), and while a policy is set the native checks (navigations, `fetch` and every redirect hop) refuse a numeric host not written in that spelling (`0177.0.0.1`, which WebKit reads as 127.0.0.1 and the system resolver `fetch` uses as 177.0.0.1) and an IPv4 address written as IPv6 (`[::ffff:127.0.0.1]`), so an exact prohibited address is never reached under another spelling (`BrowserReplNumericHostTests`); a port in a pattern must match; unsafe patterns are refused instead of ignored |
| Redirect or link to a blocked domain | in a tab the session opened, the driver cancels the navigation (the tab stays on its page), logs it as `cancelled` and fails the action that caused it; a tab the user owns is never navigated away for the policy: reads of and input on it fail while it shows a blocked page | 32-agent-tools `policy-after-link` | better: reference C loads the page and then leaves it |
| Load and save cookies and storage | `session.storageState({ path, urls, all })`, `session.setStorageState(stateOrPath)`, `page.context().storageState()` (Playwright's format) | unit: agent-tools `storage state: cookies…`, `storage state: scoped…`, `storage state: an empty urls list…`, `storage state: sites…`, `cookie and storage-state scope…`, `storage state reads and writes localStorage only…` | better: by default only the current tab's sites (registrable domain: `docs.google.com` saves `google.com` cookies and origins) are saved, so a state file never carries the rest of the user's profile; `{ all: true }` saves the whole profile, `{ urls }` what those URLs see (absolute http(s) URLs; an empty list is the current tab's sites, never the whole profile); `page.context().storageState()` scopes to that page. Cookies and localStorage come from, and go back to, the page's own data store (a private tab's or the session's proxy store is not the user's profile): localStorage is read and written only through open tabs in that store, and an origin none of them shows is restored in a background tab of that store. Registrable domains come from the system's Public Suffix List (CFNetwork, as WebKit uses), the same list the driver scopes `clearCookies` with; cookies of sites the domain policy blocks are left out |
| Track downloads and list downloaded files | `session.downloads()`, `page.waitForEvent("download")`, `download.path()` | 32-agent-tools `downloads`, 10-files | same |
| Download PDFs automatically | `page.pdf()` or `fetch` the PDF and `fs.writeFileSync` | 14-screenshots, 21-fs | skipped: WebKit shows PDFs inline; saving is one explicit call |
| Viewport size, window size, device scale factor | `page.setViewportSize(size)` | 22-api-surface `viewport` | same (scale factor follows the screen) |
| Headless mode | hidden tabs render off screen without taking focus | 20-session | same |
| Keep the browser alive after a task | named sessions; `page.keep()` | 20-session | same |
| Browser launch settings: profile directory, connection to a running browser, executable, release channel, command-line arguments, sandbox, developer tools, deterministic rendering, disabled web security | none | | skipped: the REPL drives the user's cmux browser and its profile; it launches no browser |
| User agent, extra HTTP headers | `session.configure({ userAgent, extraHTTPHeaders })` | diff `edge.context-options` | same: applies to the tabs the session created (a user's tab it drives keeps its own) and is undone when it ends or passes `null`. Headers go on main-frame GET navigations (a navigation without them restarts with them, as the user-agent policy does); WebKit has no request interception, so subresource requests do not carry them |
| Proxy | `session.configure({ proxy: { server: "http://h:p" \| "socks5://h:p", username, password, bypass } })` | diff `edge.context-options` | same: tabs the session opens afterwards use a private, non-persistent data store that connects through the proxy (HTTP CONNECT or SOCKS5), so the user's profile and its other tabs are not proxied; such tabs start without the profile's cookies |
| Permissions (geolocation, clipboard, notifications) | `session.configure({ permissions: ["camera", "microphone", "geolocation", "notifications"] })`; the per-tab clipboard `page.clipboard` | diff `edge.context-options`, `edge.permission-*`, 19-clipboard | same: a granted permission is answered at once, the rest denied at once (no prompt nobody can answer). A geolocation grant reads macOS Location Services (no coordinates override); a camera or microphone grant opens the real device and macOS may ask the user once; `clipboard-read` is not grantable because WebKit would read the system clipboard |
| Video recording, an animated GIF of the run | `session.record()`; `stop()` writes a PNG after each action and navigation and `run.png`, an animated PNG of them | 32-agent-tools `record`; unit: agent-tools `buildApng…` | same: frames per action rather than continuous video; no task text drawn on frames |
| Trace files | `trace.jsonl` from `session.record()`: time, tab, method, URL, frame file | 32-agent-tools `record` | same |
| HAR recording | `page.on("request" \| "response")` | 16-network-console | skipped: WebKit's resource-load delegate gives no timings or bodies, so a HAR file would be hollow |
| CAPTCHA solving, default extensions (ad and cookie-banner blockers, with domains exempt from cookie blocking) | none | | skipped: no CAPTCHA solving ([site-tools.md](site-tools.md) decisions); WKWebView loads no extensions |
| Demo mode (in-page log panel) | `session.name(label)` labels the session's tabs; `page.highlight()` | 20-session, 32-agent-tools `highlight` | skipped: the panel shows a reference C agent's thoughts; there are none in cmux |

## Secrets

Reference C keeps credentials out of the model's context. The model writes a
placeholder with the secret's name, and the value is substituted when typed,
if the page's domain matches. In cmux the model is the caller, so the
value comes from a file or from code it writes.

What `secrets.load(path)` protects: the native session reads the file (it
must be inside the session directory or its own temporary directory, like any
`fs` path), so the values never enter the runtime, and every value is
masked wherever the session hands text back, including `fs.readFile` of the
file (text or bytes). It does not hide the file before the load: the
agent's own `fs` calls can read it then, and a value the agent's code
holds that way and transforms (splits, reverses, re-encodes) is not masked. `secrets.set(name, value)`
puts a value the agent's code already holds in the store; it protects later
output, not that code. Keep secret files where the agent is not told to
look, and prefer the credential sheet (`sites.browserAuth`) for passwords a
person types.

Values are kept by the native session, never in the JavaScript context agent
code runs in: `secret(name)` is a handle, and the session substitutes the
value only into the driver's text input, where the driver checks the
focused frame's own origin (WebKit's record, not page script) against the
secret's domains on every call, including retries. Redaction is native too,
so replacing runtime objects does not unmask anything. What it cannot stop:
a filled field belongs to the page, so page scripts, and code the agent
runs in the page, can read its value and transform it past the masks
(reversed, split, compressed, hex-encoded, Base64 twice or broken across
lines).

    secrets.load("./secrets.json")       // { "example.com": { "user": "...", "pw": "..." } }
    secrets.set("otp", base32Seed, { domains: ["example.com"], totp: true })
    await page.getByLabel("Password").fill(secret("pw"))

| Reference C | cmux | Proof | Verdict |
| --- | --- | --- | --- |
| Placeholders substituted at type time | `locator.fill(secret(name))`, `locator.type(secret(name))`, `pressSequentially` (the value is inserted in one piece, not key by key) | unit: agent-tools `secrets: a registered value never appears…` | same |
| Secrets scoped by domain (a map from domain to names and values) | `secrets.load(file \| object)` takes that shape; `secrets.set(name, value, { domains })` | 32-agent-tools `secret-*` | better: the frame that receives the text must match, so a cross-origin iframe on an allowed page cannot get it; a domain-only pattern needs https (or loopback http); a secret without domains is refused (reference C allows one everywhere) |
| TOTP secrets for two-factor codes | `{ totp: true }` (or a name with reference C's two-factor suffix) types the current 6-digit code; the codes a server still accepts (the current 30-second window and one on each side) are masked as `<secret:name>` where they stand as a whole number, also a result's number, and in captures on the secret's domains | unit: agent-tools `totp…`, `secrets: a TOTP secret…` | same |
| Values never in the model's context | masked natively as `<secret:name>` in printed output, the output spill file every file the REPL writes and every file `fs.readFile` returns (text or bytes), error messages, listener errors, every driver result and event (snapshot, `evaluate`, `inputValue`, title, URL, console, `content()`, `markdown()`, `tabs.content`), `fetch` URLs, headers and bodies (binary ones by the value's bytes), exports, the trace and storage state; percent-encoded (either hex case, `+` for a space, also twice as in a URL inside a redirect parameter, and `%uXXXX`), JSON- and JavaScript-escaped (`\"`, `\uXXXX` for any character with surrogate pairs, `\u{X}`, `\xHH`) and HTML-escaped forms (named, decimal and hex references, with or without the semicolon), character by character in any mix, and Base64 or base64url that decodes to a value (a Basic `Authorization` header, `"x" + btoa(value)`: every run is decoded from each of its first four characters; a value under 4 bytes, which turns up by chance in unrelated runs, only at a run's own offset or in a run no more than 3 characters longer than its encoding) too, in one linear pass; masking that would grow an output by more than 8 MiB (a body full of a one-character secret) refuses a fetch or file and withholds a text, rather than allocate gigabytes; `keyboard.type(secret)` is refused | unit: agent-tools `secrets: a registered value never appears…`, 32-agent-tools `secret-*`, `output:10` | better: reference C masks only its own logs, while its DOM state still shows a typed value in a text field |
| | screenshots, recordings and PDFs: for the length of each capture, in frames whose origin is on a secret's domains, a text field whose value holds it, and any element whose own text holds it, renders with `-webkit-text-security: disc` like a password field, then is restored. The driver does this in a content world of its own that, like the agent's world, sees closed shadow roots; values are never sent to page scripts or to other frames, and concurrent captures keep a per-element count. It fails closed: the capture is refused (`invalid`, try again) when the mask step fails in a frame on a secret's domains, or when a scan after the capture finds an element holding a value that renders unmasked (the page dropped the mask or added the value meanwhile) | 32-agent-tools `secret-screenshot`, `secret-screenshot-concurrent` | better: reference C's screenshots show a typed value; the check compares field pixels across two secrets and against the same text unregistered. A secret drawn on a canvas or in an image, split across elements, shown and hidden again within the capture, or echoed in a frame of another origin, is not masked |

## Custom actions, MCP and the agent loop

| Reference C | cmux | Proof | Verdict |
| --- | --- | --- | --- |
| Register custom actions with a description, parameters and domains; exclude built-in actions | `tools.register(name, fn, { description, params, domains })`, `tools.list()`, `tools.call()`, `tools.unregister()`; tools persist in a named session | 32-agent-tools `tools-*` | same |
| Skills (cloud-hosted recorded APIs) | `sites` tools ([site-tools.md](site-tools.md)) and `tools.register` | sites/*.test.mjs | same |
| Gmail 2FA integration, Google Sheets actions | `sites.gmail`, `sites.googleSheets` | sites/*.test.mjs | same (owned by the site tools) |
| MCP server with one tool per browser action, over stdio | `cmux browser repl mcp [--session NAME]`: tools `eval` (code to output), `snapshot`, `screenshot` (an image), `tabs`, `reset`, run in one REPL session (one per server process by default, `--session` to share one) through the same `browser.repl.eval`/`browser.repl.reset` socket methods | unit: mcp `repl mcp: handshake…` | better (the test runs against a tagged CLI given in `PARITY_CMUX_CLI`): one `eval` tool reaches the whole API (Playwright, refs, `sites`, `session`) instead of a fixed tool per action, and variables persist between calls |
| MCP client (the agent uses MCP tools) | the calling agent's own MCP client | | skipped: no agent loop in cmux |
| Structured output for the final result and for extraction | the agent returns its own JSON; `page.extract(spec)` | 32-agent-tools `extract` | same |
| A judge model that grades the run, optionally against a known answer | none | | skipped: a model grading its own run belongs to the agent harness |
| Planner, loop detection, message compaction, memory, prompts, flash and thinking modes, vision settings, fallback model, cost and token tracking, telemetry, cloud sync, sandbox | none | | skipped: agent-loop internals with no meaning for a REPL an outside agent drives |
| Actions run before the task, rerun of a recorded history, variable detection | a REPL script is the rerunnable artifact; `session.record()` traces a run | 32-agent-tools `record` | skipped: rerunning recorded indices is replaced by rerunning code |
| Low-level page API: elements by CSS selector, an element from a description, content extraction | locators; the model-backed calls are the caller's reasoning over `snapshot()` or `page.markdown()` | 15-locators | same for selectors; skipped for model calls |
