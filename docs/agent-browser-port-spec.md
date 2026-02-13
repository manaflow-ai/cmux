# Agent-Browser Port Spec

Last updated: February 13, 2026  
Source inventory snapshot: `vercel-labs/agent-browser` @ `03a8cb9`

This document tracks implemented behavior and remaining parity gaps for the cmuxterm browser port.

## Goals

1. Provide an LLM-friendly browser automation API in cmuxterm with stable handles.
2. Keep v1 CLI/socket behavior working while v2 reaches full parity.
3. Port `agent-browser` command surface (where meaningful for `WKWebView`).
4. Ensure move/reorder operations preserve `surface_id` identity.
5. Rebuild/port tests so both v1 and v2 suites pass before deprecating v1.

## Validation Status

As of February 12, 2026:
1. `./scripts/run-tests-v1.sh` passes on `cmux-vm`.
2. `./scripts/run-tests-v2.sh` passes on `cmux-vm`.
3. Browser parity suites passing in v2: `test_browser_api_comprehensive.py`, `test_browser_api_p0.py`, `test_browser_api_extended_families.py`, `test_browser_api_unsupported_matrix.py`, and `test_browser_cli_agent_port.py`.
4. Visual suite note: `tests/test_visual_screenshots.py` and `tests_v2/test_visual_screenshots.py` both report D12 (`Nested: Close Top of T-shape`) as a known non-blocking VM failure when it reproduces (`VIEW_DETACHED`).

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
12. `dialog`: `accept|dismiss`
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

- [x] Lock method names/payload schemas for all new `browser.*` methods.
- [x] Add schema validation for each new method with strict error codes (`invalid_params`, `not_found`, `invalid_state`).
- [x] Add `browser` command group in `CLI/cmuxterm.swift` that accepts agent-browser-style command grammar.
- [x] Add `--surface` mandatory targeting (with fallback from `system.identify` when explicitly desired).
- [x] Add consistent JSON output mode for all browser commands.
- [x] Implement short-ref allocator and resolver for `window/pane/workspace/surface` (`window:N`, `workspace:N`, `pane:N`, `surface:N`).
- [x] Add `--id-format refs|uuids|both` across relevant CLI commands (`--json` default refs, plain-text default refs).
- [x] Ensure browser placement APIs always return decision-rich metadata (resolved target pane, created splits, resulting handles).

### Phase 1: Core Browser Parity (P0)

- [x] Implement `browser.snapshot` (with refs).
- [x] Implement `browser.eval`.
- [x] Implement `browser.wait` variants: selector, timeout, URL pattern, load state, function, text.
- [x] Implement click family: `click`, `dblclick`, `hover`, `focus`.
- [x] Implement input family: `type`, `fill`, `press`, `keydown`, `keyup`.
- [x] Implement checkbox/select family: `check`, `uncheck`, `select`.
- [x] Implement scrolling family: `scroll`, `scroll_into_view`.
- [x] Implement getters: text/html/value/attr/url/title/count/box/styles.
- [x] Implement state checks: visible/enabled/checked.
- [x] Implement screenshots (surface/full-page where feasible).

### Phase 2: Locator + Session Parity (P1)

- [x] Implement `browser.find.role`.
- [x] Implement `browser.find.text`.
- [x] Implement `browser.find.label`.
- [x] Implement `browser.find.placeholder`.
- [x] Implement `browser.find.alt`.
- [x] Implement `browser.find.title`.
- [x] Implement `browser.find.testid`.
- [x] Implement `browser.find.nth|first|last`.
- [x] Implement frame context switching (`frame.select`, `frame.main`).
- [x] Implement dialog handling (`accept`, `dismiss`, optional prompt text).
- [x] Implement download waiting.
- [x] Implement console/error buffers and retrieval.
- [x] Implement highlight helper.
- [x] Implement browser state save/load format.

### Phase 3: Move/Reorder + Window/Workspace Integration

- [x] Implement `surface.move` with handle-based destination rules.
- [x] Implement `surface.reorder` within pane.
- [x] Implement cross-workspace surface moves.
- [x] Implement cross-window surface moves.
- [x] Implement `workspace.reorder`.
- [x] Add CLI commands for tab/surface reordering and moving (`move-surface`, `reorder-surface`, `reorder-workspace`).
- [x] Add response payloads that confirm final `window_id/workspace_id/pane_id/surface_id`.
- [x] Add explicit invariants tests for `surface_id` stability.

### Phase 4: Advanced/Optional Parity (P2)

- [ ] Evaluate feasibility of request interception/mocking in `WKWebView`; implement supported subset.
- [ ] Add emulation settings that are feasible in `WKWebView`.
- [ ] Add trace/recording equivalents where practical.
- [x] Add script/style injection helpers.
- [x] Document unsupported commands with explicit error `not_supported`.

### Phase 5: Compatibility + Migration

- [x] Add v1-to-v2 shim for migrated command families.
- [x] Keep existing v1 behavior unchanged while shim is active.
- [ ] Document v1/v2 mapping table for all browser/topology commands.
- [ ] Add deprecation warnings only after parity + test completion.

### Phase 6: Docs + Examples

- [x] Update `docs/v2-api-migration.md` with browser parity status.
- [ ] Add dedicated browser automation doc in `docs-site`.
- [ ] Add examples for LLM workflow: identify -> choose surface -> snapshot -> act -> verify.
- [ ] Add explicit "surface vs pane vs workspace vs window" section to CLI docs.

## Test Port Plan (Comprehensive)

### Port Targets from `agent-browser`

1. `src/browser.test.ts` -> ported/adapted into:
   - `tests_v2/test_browser_api_p0.py`
   - `tests_v2/test_browser_api_comprehensive.py`
   - `tests_v2/test_browser_api_unsupported_matrix.py`
2. `src/actions.test.ts` -> adapted negative coverage in `tests_v2/test_browser_api_comprehensive.py` (`invalid_params`, `not_found`, `timeout`).
3. `src/protocol.test.ts` -> adapted browser command/shape validation in `tests_v2/test_browser_api_unsupported_matrix.py` and existing `CLI/cmuxterm.swift` command grammar checks.
4. `test/file-access.test.ts` and `test/launch-options.test.ts` -> partially applicable to `WKWebView`; currently tracked as follow-up parity work (not blocking current browser method coverage).
5. `src/daemon.test.ts`, `src/stream-server.test.ts`, `test/serverless.test.ts`, `src/ios-manager.test.ts` -> out-of-scope for cmuxterm browser parity (different transport/runtime).

### Implemented cmux Browser Suites

1. `tests_v2/test_browser_api_p0.py`
2. `tests_v2/test_browser_api_comprehensive.py`
3. `tests_v2/test_browser_api_unsupported_matrix.py`
4. `tests_v2/test_browser_goto_split.py`
5. `tests_v2/test_browser_panel_stability.py`
6. `tests_v2/test_browser_custom_keybinds.py`

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
2. Default browser placement without explicit target is caller-relative: reuse the nearest right sibling pane; if none exists, split right from the caller pane.
3. Deeply nested layouts use local split ancestry: choose the nearest right sibling leaf in the caller's subtree path and avoid reshuffling unrelated panes.
4. Network parity target is full parity (not block-only phase).
5. Output shape is cmuxterm-native overall, but `browser.snapshot` and selector `not_found` diagnostics intentionally mirror agent-browser semantics for agent usability.
6. ID model accepts UUIDs and short refs.
7. Short ref format uses full words and colon: `surface:N`, `pane:N`, `workspace:N`, `window:N`.
8. Short refs are global per daemon, monotonic, and never reused until daemon restart.
9. Plain-text CLI output defaults to short refs.
10. JSON output defaults to short refs (UUIDs available via `--id-format uuids|both`).
11. CLI supports `--id-format refs|uuids|both` for output shaping.
12. Browser create/move commands should expose enough placement/result metadata for agents to make deterministic follow-up decisions.
13. Reuse behavior is implicit by default (caller-relative right-pane reuse); explicit handles can still force deterministic targeting.
14. `browser fill` accepts empty text and treats it as a clear operation.
15. Mutating browser actions can opt into post-action verification snapshots via `snapshot_after` (`--snapshot-after` in CLI), returning `post_action_snapshot` (+ refs/title/url).
16. Legacy `new-pane`/`new-surface` plain output prefers short `surface:N` refs under default CLI ID formatting.

## Remaining Open Decisions

1. Unsupported command policy: strict `not_supported` errors vs best-effort fallback for commands that cannot be implemented on `WKWebView` with correct semantics.
2. Whether to expose protocol-only agent-browser actions in first public release of `cmuxterm browser` or gate them behind a second rollout phase.
