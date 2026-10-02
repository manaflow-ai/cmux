# browser-use parity

Every agent-facing capability of [browser-use](https://github.com/browser-use/browser-use)
(commit `4cbe921`, 2026-09-26) mapped to `cmux browser repl`. browser-use runs
its own model loop over a numbered DOM list and a Python tool registry; the
REPL is driven by an outside agent in JavaScript, so a browser-use tool
becomes a Playwright call, a ref, or one of the additions in
`Resources/browser-repl/agent-tools.js`. Nothing in cmux calls a model:
browser-use's model-backed tools (`extract` with a query, `get_element_by_prompt`)
map to deterministic reads the calling agent reasons over.

Verdicts: **same** (the capability exists with equivalent behavior),
**better** (it exists and closes a gap browser-use leaves, stated in the
row), **skipped** (not built, with the reason). Proof tests are in
[tests/browser-parity](../../tests/browser-parity/README.md): `NN-name` is a
scenario (`key` its golden value), `unit:` a `node --test` file.

## Tools (browser-use `tools/service.py`)

| browser-use | cmux | Proof | Verdict |
| --- | --- | --- | --- |
| `navigate(url, new_tab)` | `page.goto(url)`, `tabs.open(url)` | 12-navigation, 13-tabs | same |
| `go_back` | `page.goBack()` | 12-navigation | same |
| `search(query, engine)` (opens a results page) | `search(query, { engine: "duckduckgo" \| "bing" \| "google", limit })` returns `[{ title, url, snippet }]`; Google goes through `sites.googleSearch` | 32-agent-tools `search-duckduckgo`, `search-bing` | better: structured results instead of a page to read; a CAPTCHA page is an error, not an empty result |
| `click(index)`, `click(x, y)` | `page.locator("e5").click()`, `page.mouse.click(x, y)` | 17-refs, 04-actions-diff, 22-api-surface `mouse-down-up` | better: refs never renumber; real, trusted input with Playwright actionability |
| new-tab detection after a click | `page.on("popup")`, `waitForEvent("popup")` | 13-tabs | same |
| `input(index, text, clear)` | `locator.fill(text)`, `locator.pressSequentially(text)` | 05-input | same |
| `upload_file(index, path)` | `locator.setInputFiles(path)`, `page.fileChooser()` | 10-files | same |
| `switch(tab_id)`, `close(tab_id)` | `tabs.use(id)`, `page.close()` | 13-tabs | same |
| `send_keys("Control+o")` | `page.keyboard.press("Control+o")` | 05-input, 22-api-surface `keyboard-primitives` | same |
| `find_text` (scroll to text) | `page.scrollToText(text)` returns the element's ref | 32-agent-tools `scroll-to-text` | same |
| `scroll(down, pages, index)` | `page.scroll({ pages, target })` (native wheel; negative pages scroll up), `page.scrollInfo(target?)` | 32-agent-tools `scroll-page`, `scroll-element` | same |
| `dropdown_options(index)` | `page.dropdownOptions(ref)`: `<select>` options, or an open ARIA combobox, listbox or menu with a ref per option; the snapshot also prints `[options: …]` | 32-agent-tools `dropdown-select`, `dropdown-aria`, 01-snapshot | same |
| `select_dropdown(index, text)` | `locator.selectOption(label)`; an ARIA option's ref from `dropdownOptions` is clicked | 04-actions-diff, 32-agent-tools `dropdown-aria-ref-clicks` | same |
| `extract(query, output_schema)` (page to Markdown, then a model) | `page.markdown({ main, links, images, start, maxChars })`; `page.extract({ $: ".item", name: "h3", url: "a@href" })` for structured data by selectors | 32-agent-tools `markdown*`, `extract*`; 33-markdown-corpus; unit: agent-tools `markdown: chunks…` | better: no model call, deterministic; iframes (cross-origin) and closed shadow roots in place; on the nine-page corpus every text link Chrome shows is kept and no text Chrome hides appears; a cut repeats the table header and names the next `start` |
| `extract(start_from_char)`, `already_collected` | `page.markdown({ start, maxChars })`; deduplication is the caller's code | unit: agent-tools `markdown: chunks…` | same |
| `search_page(pattern, regex, css_scope)` | `page.searchText(pattern, { regex, caseSensitive, context, scope, limit })` → `{ total, matches: [{ match, context, ref }] }` | 32-agent-tools `search-text*` | better: each match carries a ref that works as a locator |
| `find_elements(selector, attributes)` | `page.locator(sel).evaluateAll(...)`, `page.extract([sel + "@attr"])` | 15-locators, 32-agent-tools `extract` | same |
| `screenshot(file_name)` | `screenshot({ path })`, `page.screenshot()` | 14-screenshots | same |
| `save_as_pdf(paper_format, landscape, …)` | `page.pdf({ format, landscape, printBackground, margin, path })` | 14-screenshots | same (header and footer templates: WebKit's print has none) |
| `evaluate(code)` and its quote auto-repair | `page.evaluate(fn, arg)` | 05-input, 15-locators | same: the agent writes real JavaScript, so there is nothing to repair |
| `wait(seconds)` | `sleep(ms)`, `page.waitForTimeout(ms)`, Playwright auto-waits | 09-dialogs-held | same |
| `write_file`, `read_file`, `replace_file` | `fs.writeFileSync`, `fs.readFileSync`, `fs.appendFileSync` (sandboxed to the cwd and temp) | 21-fs | same |
| `write_file` to `.pdf`/`.docx` from Markdown | none | | skipped: a converter is outside browser operation; the agent's own tools write documents |
| `done(text, success, files)`, structured `done` | the REPL value the agent returns | | skipped: an agent-loop terminator; the outside agent ends its own task |

## DOM representation (`dom/`)

[representation-comparison.md](representation-comparison.md) compares the formats in detail.

| browser-use | cmux | Proof | Verdict |
| --- | --- | --- | --- |
| indexed interactive elements `[12]<button>` | snapshot refs `[ref=e12]` usable as locators | 01-snapshot, 17-refs | better: a ref is bound to its node and never reused; stale refs fail with a reason |
| `*[12]` new-element markers | the snapshot prints its diff against the previous one | 04-actions-diff, 18-print | better: added, removed and changed lines with context |
| cross-origin iframes (`max_iframes`, depth) | every frame inlined with `fN` ref prefixes, at any depth | 06-frames, 25-nested-frames, 31-frame-calls | same |
| shadow DOM | open and closed shadow roots pierced | 07-shadow, 26-closed-shadow | better: closed roots too |
| page and element scroll info ("N pages above/below") | `page.scrollInfo(target?)`; snapshot `{ viewport: true }` notes what is off screen; `[scrollable]` marks scroll regions | 32-agent-tools `scroll-page`, 28-compact | same |
| paint-order occlusion filtering | not filtered; a click on a covered element fails with Playwright's hit-target check naming the cover | 15-locators | skipped: removing covered elements hides controls behind transient overlays; acting reports occlusion exactly |
| `highlight_elements` overlay, interaction highlight | `page.highlight(targets?)`, `locator.highlight()`, `page.hideHighlight()`; `screenshot({ annotate: true })` | 32-agent-tools `highlight`, 14-screenshots | same |
| `include_attributes` | snapshot `{ urls: true }`, `page.extract` with `@attr`, locators | 01-snapshot, 32-agent-tools `extract` | same |

## Browser session and profile (`browser/`)

| browser-use | cmux | Proof | Verdict |
| --- | --- | --- | --- |
| `allowed_domains`, `prohibited_domains`, `block_ip_addresses` | `session.allowedDomains([...], { lock })`, `session.prohibitedDomains([...])`, `session.blockIPAddresses(true)`, `session.blockedNavigations()` | 32-agent-tools `policy-*`; unit: agent-tools `domain patterns` | better: also covers the REPL's `fetch`, `tabs.content` and site tools, and blocks subresources (images, scripts, styles, fonts, media, XHR and fetch, WebSockets, iframes) through a WebKit content rule list in the tabs the session drives, where browser-use filters navigations only (32-agent-tools `policy-subresources`); `{ lock: true }` keeps the agent from lifting it; a port in a pattern must match; unsafe patterns are refused instead of ignored |
| redirect or link to a blocked domain | the tab goes to `about:blank` and the action, or the next read of or action on the tab (each checks the live URL first), fails | 32-agent-tools `policy-after-link` | same |
| `storage_state` load and save | `session.storageState({ path, urls, all })`, `session.setStorageState(stateOrPath)`, `page.context().storageState()` (Playwright's format) | unit: agent-tools `storage state: cookies…`, `storage state: scoped…`, `storage state: registrable…` | better: by default only the current tab's sites (registrable domain: `docs.google.com` saves `google.com` cookies and origins) are saved, so a state file never carries the rest of the user's profile; `{ all: true }` saves the whole profile, `{ urls }` what those URLs see; `page.context().storageState()` scopes to that page. Registrable domains use a built-in list of common multi-label suffixes (`co.uk`, `github.io`, ...), not the full Public Suffix List |
| downloads tracking, `downloaded_files` | `session.downloads()`, `page.waitForEvent("download")`, `download.path()` | 32-agent-tools `downloads`, 10-files | same |
| `auto_download_pdfs` | `page.pdf()` or `fetch` the PDF and `fs.writeFileSync` | 14-screenshots, 21-fs | skipped: WebKit shows PDFs inline; saving is one explicit call |
| `viewport`, `window_size`, `device_scale_factor` | `page.setViewportSize(size)` | 22-api-surface `viewport` | same (scale factor follows the screen) |
| `headless` | hidden tabs render off screen without taking focus | 20-session | same |
| `keep_alive` | named sessions; `page.keep()` | 20-session | same |
| `user_data_dir`, `profile_directory`, `cdp_url`, `executable_path`, `channel`, `args`, `chromium_sandbox`, `devtools`, `deterministic_rendering`, `disable_security` | none | | skipped: the REPL drives the user's cmux browser and its profile; it launches no browser |
| `user_agent`, `headers` | `session.configure({ userAgent, extraHTTPHeaders })` | diff `edge.context-options` | same: applies to every tab the session drives and is undone when it ends or passes `null`. Headers go on main-frame GET navigations (a navigation without them restarts with them, as the user-agent policy does); WebKit has no request interception, so subresource requests do not carry them |
| `proxy` | `session.configure({ proxy: { server: "http://h:p" \| "socks5://h:p", username, password, bypass } })` | diff `edge.context-options` | same: tabs the session opens afterwards use a private, non-persistent data store that connects through the proxy (HTTP CONNECT or SOCKS5), so the user's profile and its other tabs are not proxied; such tabs start without the profile's cookies |
| `permissions` (geolocation, clipboard, notifications) | `session.configure({ permissions: ["camera", "microphone", "geolocation", "notifications"] })`; the per-tab clipboard `page.clipboard` | diff `edge.context-options`, `edge.permission-*`, 19-clipboard | same: a granted permission is answered at once, the rest denied at once (no prompt nobody can answer). A geolocation grant reads macOS Location Services (no coordinates override); a camera or microphone grant opens the real device and macOS may ask the user once; `clipboard-read` is not grantable because WebKit would read the system clipboard |
| `record_video_dir`, `generate_gif` | `session.record()`; `stop()` writes a PNG after each action and navigation and `run.png`, an animated PNG of them | 32-agent-tools `record`; unit: agent-tools `buildApng…` | same: frames per action rather than continuous video; no task text drawn on frames |
| `traces_dir` | `trace.jsonl` from `session.record()`: time, tab, method, URL, frame file | 32-agent-tools `record` | same |
| `record_har_path` | `page.on("request" \| "response")` | 16-network-console | skipped: WebKit's resource-load delegate gives no timings or bodies, so a HAR file would be hollow |
| `captcha_solver`, `enable_default_extensions` (ad and cookie-banner blockers, `cookie_whitelist_domains`) | none | | skipped: no CAPTCHA solving ([site-tools.md](site-tools.md) decisions); WKWebView loads no extensions |
| `demo_mode` (in-page log panel) | `session.name(label)` labels the session's tabs; `page.highlight()` | 20-session, 32-agent-tools `highlight` | skipped: the panel shows a browser-use agent's thoughts; there are none in cmux |

## Secrets

browser-use's `sensitive_data` keeps credentials out of the model's context:
the model writes `<secret>name</secret>` and the value is substituted when
typed, if the page's domain matches. In cmux the model is the caller, so the
value comes from a file or code it does not print.

    secrets.load("~/.config/agent/secrets.json")       // { "example.com": { "user": "...", "pw": "..." } }
    secrets.set("otp", base32Seed, { domains: ["example.com"], totp: true })
    await page.getByLabel("Password").fill(secret("pw"))

| browser-use | cmux | Proof | Verdict |
| --- | --- | --- | --- |
| placeholders substituted at type time | `locator.fill(secret(name))`, `locator.type(secret(name))`, `pressSequentially` | unit: agent-tools `secrets: a registered value never appears…` | same |
| domain-scoped secrets (`{ domain: { name: value } }`) | `secrets.load(file \| object)` takes that shape; `secrets.set(name, value, { domains })` | 32-agent-tools `secret-*` | better: the frame that receives the text must match, so a cross-origin iframe on an allowed page cannot get it; a domain-only pattern needs https (or loopback http); a secret without domains is refused (browser-use allows one everywhere) |
| `bu_2fa_code` TOTP secrets | `{ totp: true }` (or a name ending `bu_2fa_code`) types the current 6-digit code | unit: agent-tools `totp…`, `secrets: a TOTP secret…` | same |
| values never in the model's context | masked as `<secret:name>` in printed output, the output spill file, error messages, listener errors, every driver result (snapshot, `evaluate`, `inputValue`, title, URL, console, `content()`, `markdown()`, `tabs.content`), `fetch().text()`, exports, the trace and storage state; URL-encoded, JSON and HTML forms too; `keyboard.type(secret)` is refused | unit: agent-tools `secrets: a registered value never appears…`, 32-agent-tools `secret-*`, `output:10` | better: browser-use masks only its own logs, while its DOM state still shows a typed value in a text field |
| | screenshots, recordings and PDFs: for the length of each capture, a text field whose value holds a registered secret, and any element whose own text holds one, renders with `-webkit-text-security: disc` like a password field, then is restored | 32-agent-tools `secret-screenshot` | better: browser-use's screenshots show a typed value; the check compares field pixels across two secrets and against the same text unregistered. A secret drawn on a canvas or in an image is not masked |

## Custom actions, MCP and the agent loop

| browser-use | cmux | Proof | Verdict |
| --- | --- | --- | --- |
| `@tools.action(description, param_model, domains)`, `exclude_action` | `tools.register(name, fn, { description, params, domains })`, `tools.list()`, `tools.call()`, `tools.unregister()`; tools persist in a named session | 32-agent-tools `tools-*` | same |
| skills (cloud-hosted recorded APIs) | `sites` tools ([site-tools.md](site-tools.md)) and `tools.register` | sites/*.test.mjs | same |
| Gmail 2FA integration, Google Sheets actions | `sites.gmail`, `sites.googleSheets` | sites/*.test.mjs | same (owned by the site tools) |
| MCP server (`browser_navigate`, `browser_click`, ... over stdio) | `cmux browser repl mcp [--session NAME]`: tools `eval` (code to output), `snapshot`, `screenshot` (an image), `tabs`, `reset`, run in one REPL session (one per server process by default, `--session` to share one) through the same `browser.repl.eval`/`browser.repl.reset` socket methods | unit: mcp `repl mcp: handshake…` | better (the test runs against a tagged CLI given in `PARITY_CMUX_CLI`): one `eval` tool reaches the whole API (Playwright, refs, `sites`, `session`) instead of a fixed tool per action, and variables persist between calls |
| MCP client (agent uses MCP tools) | the calling agent's own MCP client | | skipped: no agent loop in cmux |
| structured output (`output_model_schema`), `extraction_schema` | the agent returns its own JSON; `page.extract(spec)` | 32-agent-tools `extract` | same |
| judge (`use_judge`, `ground_truth`) | none | | skipped: a model grading its own run belongs to the agent harness |
| planner, loop detection, message compaction, memory, prompts, flash and thinking modes, vision settings, fallback model, cost and token tracking, telemetry, cloud sync, sandbox | none | | skipped: agent-loop internals with no meaning for a REPL an outside agent drives |
| `initial_actions`, history rerun, variable detection | a REPL script is the rerunnable artifact; `session.record()` traces a run | 32-agent-tools `record` | skipped: rerunning recorded indices is replaced by rerunning code |
| `actor` API (`get_elements_by_css_selector`, `get_element_by_prompt`, `extract_content`) | locators; the model-backed calls are the caller's reasoning over `snapshot()` or `page.markdown()` | 15-locators | same for selectors; skipped for model calls |
