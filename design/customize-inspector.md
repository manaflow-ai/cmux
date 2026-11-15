# Customize Inspector

Hold Option and move the pointer over the window. The big part under the pointer gets an outline, and a card opens beside it. The card shows:

- the part's name;
- the settings that change it;
- the theme colors it paints with;
- **Change This…** and **Reset**.

Leo, 2026-11-14: "the ergonomics need to be real good like just ultra braindead".

Gallery: `customize-inspector-gallery.html` (variant A is the one built).

## What it reads

One Rust map, `cmux-action-catalog/src/customize_elements.rs`, which the app reads with the action catalog (`CustomizeElement`). The right-click Customize… row reads the same map. Its parts are:

- sidebar, sidebar section, workspace row, widget (sidebar cards);
- title bar;
- tab bar, tab;
- pane;
- chat composer, chat messages.

`tests/customize_elements.rs` (Rust) and `CustomizeInspectorTests` (Swift) fail when a part has no entry, or no view answers for it.

## How it behaves

- **Opting in.** Off by default. Settings > Advanced > Labs > Customize From the Window (`customize.fromTheApp`, also in the palette, `cmux settings set customize.fromTheApp true` and MCP) turns on the inspector and the right-click Customize… rows together. Turning it off hides both again: that is the way back, and nothing else changes.
- **Starting.** Option alone, held 0.3 s (the shortcut hints' hold), with the pointer over the key window. Option with Command, Control or Shift is a chord, not the inspector.
- **Clicks.** The outline never takes a click. Only the card takes the mouse.
- **Reaching the buttons.** While the pointer is on the card, the part stays put, so the buttons can be reached with Option held or after letting go.
- **Ending.** Any of these ends it:
  - letting go of Option away from the card;
  - a key;
  - a click outside the card;
  - a scroll;
  - the window losing key.
- **Change This…** runs `customize.open` with `element`: a new chat whose composer starts `/customize <Part>: `.
- **Reset** runs `customize.reset` with `element`, which removes that part's settings so their defaults apply. The palette and the CLI run the same action (`cmux action customize-reset`).

## Look

- **Outline:** a 2 pt ring in the accent color, with the accent at 8% inside.
- **Card:** the card role's floating glass (as the shortcut hints' which-key overlay), 260 pt wide, with these rows:
  - the name, in body emphasized;
  - up to 4 settings, then "+N";
  - up to 5 colors, then "+N";
  - Reset, then Change This…. No key presses them: a key ends the inspector.
