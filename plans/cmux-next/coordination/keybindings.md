# Lane: keybindings

## Active streams
- R59 keybindings and palette customization (keybindings lead): one key dispatcher, a binding table with `when` clauses, then customization slices (`when` grammar, chords up to 4, args, negative entries, keybindings.json, catalog ops, editor page). Design and map: plans/cmux-next/keybindings.md. Touches: focus (KeyRouter), actions (ActionRegistry binding table, ActionInvocation.keyContext), browser (popup close rule), settings (shortcut editor later).

## Landed
- 2026-10-03 (this push) keys: one dispatcher in `KeyRouter.interceptKeyDown` (IME, chord, binding table with the key window's context, tier, deliver; menu display only for decided keys); `KeyBindingTable`, `KeyContext`, `WhenClause`, `KeyBindingDefaults` in CmuxNextActions; Ctrl-Tab / Ctrl-Shift-Tab / Ctrl-PageDown/Up change tabs in every surface but a terminal (Ghostty keeps them; copy mode gets them); Home is surface kind `home` (on the Home lead's `FocusTopology.Kind.conversation`). Shared-surface changes: `ActionInvocation.keyContext`, `ChordTracker.step(prefix:complete:)`, `BrowserPopupPanels.interceptKeyDown` removed (the dispatcher's popup rule replaces it).
