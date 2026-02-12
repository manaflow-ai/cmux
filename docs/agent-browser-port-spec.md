# Agent-Browser Port Spec (Planning Only)

Last updated: February 12, 2026  
Source inventory snapshot: `vercel-labs/agent-browser` @ `03a8cb9`

This document is planning-only. It does not imply implementation is complete.

## Goals

1. Provide an LLM-friendly browser automation API in cmuxterm with stable handles.
2. Keep v1 CLI/socket behavior working while v2 reaches full parity.
3. Port `agent-browser` command surface (where meaningful for `WKWebView`).
4. Ensure move/reorder operations preserve `surface_id` identity.
5. Rebuild/port tests so both v1 and v2 suites pass before deprecating v1.

## Concepts (Canonical Terms)

1. `window`: native macOS window.
2. `workspace`: sidebar entry within a window (often called "tab" in UI).
3. `pane`: split region inside a workspace.
4. `surface`: tab within a pane (terminal or browser). This is the primary automation target.
5. `panel`: internal implementation term; CLI/API should prefer `surface`.

Terminology decision:
- Public v2 API and new CLI docs should standardize on `surface` and `pane`.
- Keep `--panel` as compatibility alias in CLI until v1 is retired.

## Self-Identify Requirement

`system.identify` is the canonical "where am I?" call for agents and should remain first-class.

Required response fields for agent workflows:
1. `focused.window_id`
2. `focused.workspace_id`
3. `focused.pane_id`
4. `focused.surface_id`
5. `caller` validation result when caller context is supplied

Recommended extension for browser workflows:
1. `focused.surface_type`
2. `focused.browser.url`
3. `focused.browser.title`
4. `focused.browser.loading`

## Agent-Browser Command Inventory

### Top-Level CLI Verbs (from `cli/src/commands.rs`)

1. `open|goto|navigate`
2. `back`
3. `forward`
4. `reload`
5. `click`
6. `dblclick`
7. `fill`
8. `type`
9. `hover`
10. `focus`
11. `check`
12. `uncheck`
13. `select`
14. `drag`
15. `upload`
16. `download`
17. `press|key`
18. `keydown`
19. `keyup`
20. `scroll`
21. `scrollintoview|scrollinto`
22. `wait`
23. `screenshot`
24. `pdf`
25. `snapshot`
26. `eval`
27. `close|quit|exit`
28. `connect`
29. `get`
30. `is`
31. `find`
32. `mouse`
33. `set`
34. `network`
35. `storage`
36. `cookies`
37. `tab`
38. `window`
39. `frame`
40. `dialog`
41. `trace`
42. `record`
43. `console`
44. `errors`
45. `highlight`
46. `state`
47. `tap`
48. `swipe`
49. `device`

### CLI Subcommands

1. `get`: `text|html|value|attr|url|title|count|box|styles`
2. `is`: `visible|enabled|checked`
3. `find`: `role|text|label|placeholder|alt|title|testid|first|last|nth`
4. `mouse`: `move|down|up|wheel`
5. `set`: `viewport|device|geo|geolocation|offline|headers|credentials|auth|media`
6. `network`: `route|unroute|requests`
7. `storage`: `local|session` + `get|set|clear`
8. `cookies`: default get, plus `set|clear`
9. `tab`: default list, plus `new|list|close|<index>`
10. `window`: `new`
11. `frame`: `<selector>|main`
12. `dialog`: docs say `accept|dismiss` (parser currently only handles `accept`)
13. `trace`: `start|stop`
14. `record`: `start|stop|restart`
15. `state`: `save|load`
16. `device`: `list`

### Global Flags

1. `--json`
2. `--full|-f`
3. `--headed`
4. `--debug`
5. `--session`
6. `--headers`
7. `--executable-path`
8. `--extension` (repeatable)
9. `--cdp`
10. `--profile`
11. `--state`
12. `--proxy`
13. `--proxy-bypass`
14. `--args`
15. `--user-agent`
16. `-p|--provider`
17. `--ignore-https-errors`
18. `--allow-file-access`
19. `--device`

### Protocol Actions in `src/protocol.ts`

Counts:
1. total actions: 125
2. directly emitted by CLI parser: 93
3. protocol-only (not directly emitted by CLI parser): 32

Protocol-only action names:
1. `addinitscript`
2. `addscript`
3. `addstyle`
4. `bringtofront`
5. `clear`
6. `clipboard`
7. `content`
8. `dispatch`
9. `evalhandle`
10. `expose`
11. `har_start`
12. `har_stop`
13. `innertext`
14. `input_keyboard`
15. `input_mouse`
16. `input_touch`
17. `inserttext`
18. `keyboard`
19. `locale`
20. `multiselect`
21. `pause`
22. `permissions`
23. `responsebody`
24. `screencast_start`
25. `screencast_stop`
26. `selectall`
27. `setcontent`
28. `setvalue`
29. `timezone`
30. `useragent`
31. `video_start`
32. `video_stop`

## cmuxterm Target API (v2)

### Already Present in cmuxterm

1. `system.ping`
2. `system.capabilities`
3. `system.identify`
4. `window.list|current|focus|create|close`
5. `workspace.list|create|select|current|close|move_to_window`
6. `pane.list|focus|surfaces|create`
7. `surface.list|focus|split|create|close|drag_to_split|refresh|health|send_text|send_key|trigger_flash`
8. `browser.open_split|navigate|back|forward|reload|url.get|focus_webview|is_webview_focused`
9. notification methods and debug/test methods

### New Browser Parity Method Families (Proposed)

P0 (core parity for daily automation):
1. `browser.snapshot`
2. `browser.eval`
3. `browser.wait`
4. `browser.click`
5. `browser.dblclick`
6. `browser.type`
7. `browser.fill`
8. `browser.press|keydown|keyup`
9. `browser.hover|focus`
10. `browser.check|uncheck`
11. `browser.select`
12. `browser.scroll|scroll_into_view`
13. `browser.get.*` (`url|title|text|html|value|attr|count|box|styles`)
14. `browser.is.*` (`visible|enabled|checked`)
15. `browser.screenshot`
16. `browser.focus_webview` and `browser.is_webview_focused` (already present, keep)

P1 (important but not blocking initial parity):
1. `browser.find.*` locators (`role|text|label|placeholder|alt|title|testid|nth|first|last`)
2. `browser.frame.select`
3. `browser.frame.main`
4. `browser.dialog.respond`
5. `browser.download.wait`
6. `browser.tab.*` compatibility aliases mapped to cmux surfaces
7. `browser.console.list`
8. `browser.errors.list`
9. `browser.highlight`
10. `browser.state.save|load` (browser state in cmux context)

P2 (advanced parity / optional):
1. network interception/mocking equivalents (`route|unroute|requests|responsebody`)
2. emulation/settings (`viewport|media|offline|geolocation|permissions|headers|credentials|useragent|locale|timezone|device`)
3. trace/video/screencast/har equivalents
4. script injection utilities (`addinitscript|addscript|addstyle|dispatch|expose|evalhandle`)
5. raw input device injection (`input_mouse|input_keyboard|input_touch`)

### Object/Handle Semantics

1. stable handles: `window_id`, `workspace_id`, `pane_id`, `surface_id`
2. browser refs (`@e1`) are session-local and ephemeral
3. move/reorder must preserve `surface_id`
4. responses may include `index` for debugging/order, but requests should accept IDs

## CLI Spec (Proposed)

Primary form:
```bash
cmuxterm browser --surface <surface-id> <agent-browser-style-command...>
```

Shorthand:
```bash
cmuxterm browser <surface-id> <agent-browser-style-command...>
```

Agent discovery:
```bash
cmuxterm identify
cmuxterm capabilities
cmuxterm browser identify --surface <surface-id>   # wrapper over system.identify + browser fields
```

Flash:
```bash
cmuxterm trigger-flash [--workspace <id>] [--surface <id>]
```

Compatibility:
1. Keep v1 commands.
2. Add v1->v2 shim for migrated browser/surface commands.
3. Keep `--panel` as alias for `--surface` during migration.

## Move/Reorder Spec (Required)

Required capabilities:
1. reorder surfaces within a pane
2. move surfaces between panes in same workspace
3. move surfaces across workspaces
4. move surfaces across windows
5. reorder workspaces within window

Proposed methods:
1. `surface.move` with `surface_id` + destination (`pane_id` or `workspace_id`/`window_id`) + placement (`before_surface_id|after_surface_id|start|end`)
2. `surface.reorder` with `surface_id` + sibling anchor (`before_surface_id|after_surface_id`)
3. `workspace.reorder` with `workspace_id` + anchor (`before_workspace_id|after_workspace_id`)

Hard invariant:
1. `surface_id` must remain unchanged after all move/reorder operations.

## Comprehensive TODO

### Phase 0: Contract + Routing

- [ ] Lock method names/payload schemas for all new `browser.*` methods.
- [ ] Add schema validation for each new method with strict error codes (`invalid_params`, `not_found`, `invalid_state`).
- [ ] Add `browser` command group in `CLI/cmuxterm.swift` that accepts agent-browser-style command grammar.
- [ ] Add `--surface` mandatory targeting (with fallback from `system.identify` when explicitly desired).
- [ ] Add consistent JSON output mode for all browser commands.
- [ ] Implement short-ref allocator and resolver for `window/pane/workspace/surface` (`window:N`, `workspace:N`, `pane:N`, `surface:N`).
- [ ] Add `--id-format refs|uuids|both` across relevant CLI commands (`--json` default `both`, plain-text default refs).
- [ ] Ensure browser placement APIs always return decision-rich metadata (resolved target pane, created splits, resulting handles).

### Phase 1: Core Browser Parity (P0)

- [ ] Implement `browser.snapshot` (with refs).
- [ ] Implement `browser.eval`.
- [ ] Implement `browser.wait` variants: selector, timeout, URL pattern, load state, function, text.
- [ ] Implement click family: `click`, `dblclick`, `hover`, `focus`.
- [ ] Implement input family: `type`, `fill`, `press`, `keydown`, `keyup`.
- [ ] Implement checkbox/select family: `check`, `uncheck`, `select`.
- [ ] Implement scrolling family: `scroll`, `scroll_into_view`.
- [ ] Implement getters: text/html/value/attr/url/title/count/box/styles.
- [ ] Implement state checks: visible/enabled/checked.
- [ ] Implement screenshots (surface/full-page where feasible).

### Phase 2: Locator + Session Parity (P1)

- [ ] Implement `browser.find.role`.
- [ ] Implement `browser.find.text`.
- [ ] Implement `browser.find.label`.
- [ ] Implement `browser.find.placeholder`.
- [ ] Implement `browser.find.alt`.
- [ ] Implement `browser.find.title`.
- [ ] Implement `browser.find.testid`.
- [ ] Implement `browser.find.nth|first|last`.
- [ ] Implement frame context switching (`frame.select`, `frame.main`).
- [ ] Implement dialog handling (`accept`, `dismiss`, optional prompt text).
- [ ] Implement download waiting.
- [ ] Implement console/error buffers and retrieval.
- [ ] Implement highlight helper.
- [ ] Implement browser state save/load format.

### Phase 3: Move/Reorder + Window/Workspace Integration

- [ ] Implement `surface.move` with handle-based destination rules.
- [ ] Implement `surface.reorder` within pane.
- [ ] Implement cross-workspace surface moves.
- [ ] Implement cross-window surface moves.
- [ ] Implement `workspace.reorder`.
- [ ] Add CLI commands for tab/surface reordering and moving (`move-surface`, `reorder-surface`, `reorder-workspace`).
- [ ] Add response payloads that confirm final `window_id/workspace_id/pane_id/surface_id`.
- [ ] Add explicit invariants tests for `surface_id` stability.

### Phase 4: Advanced/Optional Parity (P2)

- [ ] Evaluate feasibility of request interception/mocking in `WKWebView`; implement supported subset.
- [ ] Add emulation settings that are feasible in `WKWebView`.
- [ ] Add trace/recording equivalents where practical.
- [ ] Add script/style injection helpers.
- [ ] Document unsupported commands with explicit error `not_supported`.

### Phase 5: Compatibility + Migration

- [ ] Add v1-to-v2 shim for migrated command families.
- [ ] Keep existing v1 behavior unchanged while shim is active.
- [ ] Document v1/v2 mapping table for all browser/topology commands.
- [ ] Add deprecation warnings only after parity + test completion.

### Phase 6: Docs + Examples

- [ ] Update `docs/v2-api-migration.md` with browser parity status.
- [ ] Add dedicated browser automation doc in `docs-site`.
- [ ] Add examples for LLM workflow: identify -> choose surface -> snapshot -> act -> verify.
- [ ] Add explicit "surface vs pane vs workspace vs window" section to CLI docs.

## Test Port Plan (Comprehensive)

### Port Targets from `agent-browser`

1. `src/protocol.test.ts` -> cmux CLI/browser parser + v2 validation tests.
2. `src/browser.test.ts` -> `tests_v2/` end-to-end browser automation coverage.
3. `src/actions.test.ts` -> error-normalization tests for cmux browser action failures.
4. `test/file-access.test.ts` -> local-file navigation policy tests in `WKWebView`.
5. `test/launch-options.test.ts` -> adapt only applicable pieces (`headers`, emulation subset, user agent if supported).
6. `src/daemon.test.ts`, `src/stream-server.test.ts`, `test/serverless.test.ts`, `src/ios-manager.test.ts` -> out-of-scope for direct parity; map only equivalent behavior where relevant.

### Proposed cmux Test Suites

1. `tests_v2/test_browser_agent_core.py`
2. `tests_v2/test_browser_agent_locators.py`
3. `tests_v2/test_browser_agent_waits.py`
4. `tests_v2/test_browser_agent_frames_dialogs.py`
5. `tests_v2/test_browser_agent_getters_checks.py`
6. `tests_v2/test_browser_agent_screenshot_eval.py`
7. `tests_v2/test_browser_agent_move_reorder.py`
8. `tests_v2/test_browser_agent_self_identify.py`
9. `tests_v2/test_browser_agent_trigger_flash.py`
10. `tests_v2/test_browser_agent_v1_shim.py`

### Test Design Rules

1. Prefer deterministic local fixtures (embedded HTML or local HTTP server), not public websites.
2. Every command gets at least one positive and one negative test.
3. Every handle-accepting API gets tests for UUID target and index-compat shim target.
4. Every move/reorder test asserts `surface_id` stability pre/post operation.
5. Browser tests must verify behavior from both focused and unfocused webview states.
6. Self-identify tests must validate `focused` and `caller` fields.

### Migration Gate Criteria

1. New browser parity tests in `tests_v2/` pass.
2. Existing v2 regression suites still pass.
3. v1 suites still pass with shim active.
4. No regressions in existing window/workspace/surface workflows.

Planned verification commands at implementation completion:
1. `ssh cmux-vm 'cd /Users/cmux/GhosttyTabs && ./scripts/run-tests-v2.sh'`
2. `ssh cmux-vm 'cd /Users/cmux/GhosttyTabs && ./scripts/run-tests-v1.sh'`

## Decision Log (Locked - February 12, 2026)

1. `cmuxterm browser tab ...` maps to browser `surface` tabs only (no separate workspace-level tab meaning inside `browser` namespace).
2. Default browser placement without explicit target is caller-relative: place to the right of caller pane; if unavailable, split down in caller pane.
3. Deeply nested layouts use local sibling placement around the caller pane and must not reshuffle unrelated panes.
4. Network parity target is full parity (not block-only phase).
5. Output shape is cmuxterm-native (no strict agent-browser JSON compatibility requirement).
6. ID model accepts UUIDs and short refs.
7. Short ref format uses full words and colon: `surface:N`, `pane:N`, `workspace:N`, `window:N`.
8. Short refs are global per daemon, monotonic, and never reused until daemon restart.
9. Plain-text CLI output defaults to short refs.
10. JSON output defaults to both UUIDs and refs.
11. CLI supports `--id-format refs|uuids|both` for output shaping.
12. Browser create/move commands should expose enough placement/result metadata for agents to make deterministic follow-up decisions.
13. Reuse behavior should be explicit by target handle (UUID/ref); no implicit reuse policy flag is required.

## Remaining Open Decisions

1. Unsupported command policy: strict `not_supported` errors vs best-effort fallback for commands that cannot be implemented on `WKWebView` with correct semantics.
2. Whether to expose protocol-only agent-browser actions in first public release of `cmuxterm browser` or gate them behind a second rollout phase.
