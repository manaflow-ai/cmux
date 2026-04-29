# Bare-key chord leaders (tmux-style prefix)

Date: 2026-04-29

## Background

PR #2528 added two-stroke chord shortcuts (e.g. `Ctrl+B` then `1`). The recorder
and routing accept any modifier-bearing prefix, but bare keys (no modifier) are
rejected at recording time by `ShortcutStroke.from(event:requireModifier:)` in
`Sources/KeyboardShortcutSettings.swift:1336–1340`, which returns
`.bareKeyNotAllowed`.

This blocks users who want a tmux-style leader such as `` ` ``, even though the
runtime matcher (`matchShortcutStroke(event:stroke:)`) does not itself require
modifiers — it only compares normalized flags + key.

The user requesting this feature uses `` ` `` as their tmux leader and wants to
recreate their tmux pane bindings (split, focus, zoom) inside cmux.

## Goals

1. Allow a bare key (no modifier) as the **first stroke of a chord shortcut**.
2. Support binding tmux-style chords like `` ` ``+`d`, `` ` ``+`-`, `` ` ``+`hjkl`,
   `` ` ``+`z` to existing cmux pane actions.
3. Provide a way to type a literal `` ` `` (double-tap leader) without requiring
   any extra user configuration.
4. Don't regress existing single-stroke shortcut behavior or existing chord
   shortcuts.

## Non-goals

- Pane-resize actions (`resizeLeft/Right/Up/Down`). The user said they use these
  rarely; they will be tracked as a follow-up.
- Sending arbitrary keystrokes/macros to the focused terminal as a generic
  bindable action.
- Per-window or per-context leader keys.

## Existing actions covered

These already exist and become bindable to chords with no code change beyond
allowing the bare-key prefix:

| tmux binding | cmux action id   | current default |
|--------------|------------------|-----------------|
| `<L>` `\|`   | `splitRight`     | `⌘D`            |
| `<L>` `-`    | `splitDown`      | `⌘⇧D`           |
| `<L>` `h`    | `focusLeft`      | `⌥⌘←`           |
| `<L>` `l`    | `focusRight`     | `⌥⌘→`           |
| `<L>` `k`    | `focusUp`        | `⌥⌘↑`           |
| `<L>` `j`    | `focusDown`      | `⌥⌘↓`           |
| `<L>` `z`    | `toggleSplitZoom`| `⌘⇧↩`           |

(`<L>` = the user's chosen bare-key leader, e.g. `` ` ``.)

## Design

### 1. Recorder: allow bare-key first chord stroke

Update `KeyboardShortcutSettings.swift` so the chord recorder accepts a bare-key
**first** stroke, while keeping the bare-key rejection for single-stroke
shortcuts.

The simplest seam:

- `ShortcutStroke.from(event:requireModifier:)` keeps its current contract
  (modifier required by default).
- The chord-recording path calls it with `requireModifier: false` for the first
  stroke when the recorder is in "chord" mode.
- The single-stroke recording path keeps `requireModifier: true`.
- Second-stroke recording already accepts bare keys (needed for `Ctrl+B` `1`);
  no change required there. Verify during implementation.

Rationale for the asymmetry: a bare-key single-stroke shortcut would intercept
the key globally (e.g., typing `` ` `` in any terminal would always fire an
action). Restricting bare keys to chord *prefixes* means `` ` `` is only consumed
while the user is mid-chord, which matches tmux semantics.

### 2. Settings file + JSON schema

`Sources/KeyboardShortcutSettingsFileStore.swift` parses chords as
`["ctrl+b", "1"]`. The string parser is already symmetric (no per-position
modifier requirement), so `["` `","d"]` should round-trip without changes.
**Verification step during implementation:** add a unit test that decodes a
bare-key first-stroke chord from settings JSON.

`web/data/cmux-settings.schema.json` does not constrain individual stroke
strings beyond `type: string` (verified). No schema change required.

### 3. Routing: implicit `<prefix><prefix>` → literal

Today, on chord mismatch the prefix is consumed and the second key passes
through to the terminal (covered by
`testChordedShortcutMismatchDoesNotConsumeSecondKey`). Keep this behavior on
mismatch. **Do not change general mismatch routing.**

Add one new rule for bare-key prefixes only:

> When a chord prefix with **no modifiers** is armed and the next key event
> matches the prefix's key with **no modifiers**, AND no configured chord
> binding matches `<prefix><prefix>`, send the prefix character to the
> focused Ghostty terminal surface (and clear the armed prefix state).

This gives users a free `send-prefix` equivalent (typing `` `` `` `` produces one
literal `` ` ``) without any configuration. An explicit user binding for
`<prefix><prefix>` always wins (configured chords are checked first, as they
are today).

Implementation seam: in the chord-second-stroke handler around
`AppDelegate.swift:12081`, after the existing chord-match loop fails to match
and before clearing `pendingConfiguredShortcutChord`, check whether
(a) the armed prefix has zero modifier flags, and
(b) the incoming event has zero modifier flags and the same key as the prefix.
If both hold, route the prefix character to the focused surface (typically
via `tabManager.focusedSurface?.sendText(...)` or the equivalent existing path
used by the terminal-input plumbing — confirm the exact API during
implementation), consume the event, clear the armed prefix.

If we cannot find a clean "send text" entry point on the focused surface, an
acceptable fallback is to repost the event as a synthesized key event into the
focused window's first responder. Prefer the direct text path.

### 4. Tests

All tests run in `cmuxTests`, following the existing
`AppDelegateShortcutRoutingTests` patterns.

**Recorder:**
- `testChordRecorderAcceptsBareKeyFirstStroke` — chord-mode recording of `` ` ``
  produces a valid stroke (no `.bareKeyNotAllowed`).
- `testSingleStrokeRecorderStillRejectsBareKey` — single-stroke recording of
  `` ` `` returns `.bareKeyNotAllowed` (regression guard).
- `testChordRecorderAcceptsBareKeySecondStroke` — chord recording of
  `` ` `` then `d` succeeds.

**Settings file:**
- `testFileStoreDecodesBareKeyChordPrefix` — `["` `","d"]` round-trips through
  `KeyboardShortcutSettingsFileStore`.

**Routing:**
- `testBareKeyChordPrefixIsConsumed` — pressing `` ` `` when bound as a chord
  prefix arms the prefix and consumes the event (terminal does not receive it).
- `testBareKeyChordTriggersOnSecondKey` — `` ` `` then `d` (bound to
  `splitRight`) executes the action.
- `testBareKeyChordMismatchKeepsExistingBehavior` — `` ` `` then `q` (q
  unbound) consumes only `` ` ``, lets `q` pass through (regression guard for
  decision Q1=a).
- `testBareKeyChordDoubleTapSendsLiteral` — `` ` `` then `` ` `` (no explicit
  binding) sends one `` ` `` to the focused terminal surface and clears the
  armed prefix.
- `testBareKeyChordDoubleTapHonorsExplicitBinding` — when the user explicitly
  binds `` ` `` `` ` `` to an action, that action fires and no literal is sent.

The literal-send tests will need a focused-surface test fixture; reuse whatever
existing tests use to assert "text was sent to terminal" if available, or add a
small seam (e.g. a test-only protocol on the surface input target).

### 5. Localization & docs

- No new user-facing strings are strictly required for the runtime change.
- The recorder UI may want a small hint when chord mode is active and the user
  presses a bare key first ("`` ` `` armed as leader") — optional polish, not
  required for correctness. If added, localize via `Resources/Localizable.xcstrings`
  per project policy.
- Update `web/app/[locale]/docs/keyboard-shortcuts/page.tsx` and the
  configuration page to mention bare-key leaders and the implicit double-tap
  literal behavior.

## Decisions log (from brainstorming)

- **Mismatch behavior:** keep current — eat prefix, pass second key. (Q1=a)
- **Implicit double-tap literal:** applies to *any* bare-key prefix, not just
  `` ` ``. Rationale: there's no existing user with a bare-key leader to break,
  and any user who picks one needs a way to type the literal. (Q2=general)
- **Pane resize actions:** deferred. (User: "less important since I don't use
  it as much.")

## Risks

- **Surprise interception in terminal:** any bare-key leader will eat that key
  in every terminal until the user disarms (Esc) or completes the chord. Users
  who pick a common shell character (`` ` ``, `;`, `,`) accept this — same as
  tmux. No mitigation beyond docs.
- **Send-literal entry point:** the cleanest API for "type a character into the
  focused surface" needs to be located in the implementation phase. If none
  exists with the right semantics for synthesized text, we may need to add a
  small helper on the surface input pipeline. Plan accordingly.
- **Recorder UI consistency:** any place that displays "chord prefix" needs to
  render bare-key prefixes correctly (a single `` ` `` glyph with no modifier
  pills). Audit `chordKey` / `keyDisplayString` rendering paths during
  implementation.
