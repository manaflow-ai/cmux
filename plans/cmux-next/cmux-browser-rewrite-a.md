# cmux-browser rewrite, Wave A: cmux-repo contracts

Lane owner: cmuxterm-hq-99. Full contract list: `docs/rewrite/contracts-a.md`
on the cmux-browser branch `rewrite/a-base`. This file holds the two contracts
that live in this repo. Both land on feat-cmux-next through its landing lane
with the unit that implements them (0e1, 0i); never on main.

## 0e1: base::Value codec backend for the C++ emitter

- New module `cmux-tui/bindings/codegen/emit_cpp_value.py`, next to
  `emit_cpp.py`, on the same IR (`spec/sdk-schema.json`).
- `generate.py --cpp-value --allowlist FILE --out DIR` writes
  `cmux_daemon_types.h` and `cmux_daemon_types.cc` in namespace
  `cmux::daemon`. Without `--cpp-value`, generate.py behaves as now (the flag
  does not change `--write`/`--check` of the SDK bindings).
- Allowlist: `{"schema": "cmux-tui-spec-allowlist-v1", "commands": [...],
  "events": [...]}`. Only the type closure of the allowlisted names is emitted.
  Output is deterministic.
- Per command `<Name>` (pascal case of the wire name): `struct <Name>Params`,
  `struct <Name>Result`, `k<Name>Method`, `k<Name>Capability` (empty when null),
  `k<Name>Since`, `base::Value::Dict Encode(const <Name>Params&)`,
  `base::expected<<Name>Result, DecodeError> Decode<Name>Result(const base::Value&)`.
  Events: one struct per event, `UnknownEvent`, `using Event = std::variant<...>`,
  `Event DecodeEvent(const base::Value::Dict&)`.
- Integers decode from an int or from a double that is an exact integer with
  magnitude below 2^53, else `DecodeError` (no silent precision loss).
  Enums get `kUnknown` (rule of `test_enum_fallback.py`). Results ignore
  unknown fields. A missing required field gives `DecodeError{path, message}`
  with a path such as `result.panes[2].id`.
- v2 resource ops are out of scope in Wave A.
- Test: golden test on a small schema fixture
  (`bindings/codegen/tests/test_emit_cpp_value.py`), run on Freestyle or cmux
  CI.

## 0i: daemon verbs for the browser

Proposed shapes, in the sdk-schema command format:
`plans/cmux-next/cmux-browser-rewrite-a-verbs.json` (status `proposed`).

| Capability | Verb | Why |
|---|---|---|
| `client-attention-v1` | raw `report-client-attention {client_id, key_window, pane?, tab?, last_input_ms_ago?}` | The notification policy moves to the daemon; `report-focus` has no key window and no last input. |
| `frontend-tab-close-request-v1` | event `frontend-browser-tab-close-requested {request_id, surface, reason?}` to the owner client; raw `answer-frontend-browser-tab-close {request_id, outcome: closing\|cancelled}`; raw `report-frontend-browser-tab-removed {surface, reason, request_id?, origin?, mutation_id?}` | Chromium owns web-tab existence: beforeunload can veto a close, and crash, `window.close()` and `chrome.tabs.remove` remove tabs without the daemon. |
| `keybindings-resolved-v1` | v2 op `keybindings.resolved` | Only if 0g finds a Rust source for the default table (today the defaults are in Swift `KeyBindingDefaults.swift`). |

Not needed (0g confirms): screen move to another workspace (raw `move-screen`
has `workspace` and `new_workspace`), `settings.set` (exists as a v2 op),
`closed.list` / `closed.reopen` (exist).

Process: 0g sends the confirmed shapes to hq-6d
(`cmux-lawrence:~/agent-mailbox/inbox/hq-6d/`). 0i records them in
`plans/cmux-next/coordination/daemon-protocol.md` in its first commit, before
code, and builds behind the capability checks if no answer comes within one
wave. Spec changes regenerate the bindings and update the command and event
count pins in the same commit.
