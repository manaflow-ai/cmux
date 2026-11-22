# Agent picker (proposal)

Status: design proposal by the ACP UI integration lead, for Leo's agent-pane lane to build (their area). Nothing is built until Leo's coordinator answers. Source studies: the reference captures in manaflow-ai/cmux-app-screenshots (private repo; product names stay there).

## Problem

The composer's agent and model choice is split: the harness comes from New Agent Chat, the model from a cascade or drill (`ModelPicker.tsx`), effort from a separate slider, and an agent with no usable account fails only after the first prompt ("OAuth session expired", "harness claude-sr is unavailable"). Nothing shows which agents route through CodeRouter, and nothing lets the user fix a missing account from the pane.

## One picker, one chip

The composer shows one chip: harness glyph, model short name, effort (`6.1-Sol · Medium`). Clicking it (or ⌘. by default, a `KeyboardShortcutSettings` entry `agentPane.openModelPicker`) opens one panel:

1. A row of harness tabs (glyph + name on hover): one per installed harness, the current one selected. A tab whose harness is unavailable shows a small warning mark. ←/→ (or ⌘1..9) switch tabs.
2. A search field, focused on open. Typing filters models across all harnesses; with a query, results group by harness, harness tab row hides. Matching is on model id, display name, provider and family, fuzzy, best first.
3. The model list for the selected harness, grouped by provider then family when the harness has more than one (opencode, pi); otherwise flat. Each row: name, capability badges, and the check on the current model. "Recent" (last 5 picks across harnesses, numbered 1-5 for keys) and "Favorites" (starred rows, star on hover) sit above the groups.
4. A reasoning row under the list: the effort steps the selected model offers (Low … Max), one segmented control, keyboard ←/→ when focused. Hidden when the model has no effort option.
5. Toggles the harness offers as config options (fast mode, plan collaboration mode), one row each.
6. The account footer: the harness's account state and route (see below).

Enter picks the highlighted model and closes; Tab moves between list, effort and toggles; Escape closes; the panel never takes app focus (it is the page's own popover).

## Capability badges

From acpmux's model catalog (`_acpmux/harnesses` and `model_catalog.rs`), shown as short gray badges, no color: context window (`1M`), reasoning (`R` when effort applies), vision, fast mode, and price tier when the catalog has it. Unknown capabilities show nothing (no guessing).

## Accounts and CodeRouter

- acpmux already reports why a harness is unavailable (`unavailable` in `_acpmux/harnesses`). The picker shows it on the harness tab and in the footer as one line ("Not signed in", "Subrouter not reachable").
- A turn that fails with an auth error (acpmux error codes for auth, or the agent's "OAuth session expired") marks the session's harness the same way, and the transcript error row offers the same action.
- The action is "Add account", which runs the existing app action `app.open` with `{app: "cmux/coderouter", command: "connectAccount"}` (CLI `cmux app open cmux/coderouter --command connectAccount`, landed f102e7bcb92), through the page's native bridge, user-initiated only. A `harness` argument is added only if CodeRouter needs it.
- Harnesses whose launcher routes through the account router (`claude-sr`, Codex through `sr`) show a "Routed" badge on their tab and the route in the footer ("via cmux-lawrence router"). The `claude` family default prefers the routed profile (decided 2026-10-03), so picking Claude Code uses it.

## Settings (cmux.json, documented, defaults tested)

`agentPane.picker.recents` (number, default 5), `agentPane.picker.favorites` (list of `harness/model`, written by the star), `agentPane.picker.hiddenHarnesses` (list), `agentPane.picker.layout` (`panel` default, `cascade`, `drill` keep the current layouts as variants behind the DEV/NIGHTLY switch so Lawrence can compare).

## Data

No new daemon state. Harnesses, models, effort and config options come from acpmux (`_acpmux/harnesses`, the session's `configOptions`); recents and favorites are client view state in cmux.json; account state comes from acpmux `unavailable` plus CodeRouter's own status when the app exposes it.

## Verification

Page tests for search ranking, grouping, keyboard flow and the account footer states; `debug.agent_pane` gets `open_menu` support for the panel and a `pick_model {harness, model, effort}` verb on the same path as a click, so the tagged-build check can run one prompt per model.
