# Home: what it is built in, and Chat Colors

**Decided: Home is Swift (AppKit).** The docked Home's Messages view, the conversation list, the transcript,
the Chief panel and their sheets stay native. The rule and its decision test are
[plans/cmux-next/language-layers.md](../plans/cmux-next/language-layers.md); the check is
`.github/language-boundaries.toml` (area `imessage-home`); a port needs Leo's approval.

This page used to be the plan to move Home to React, a seam at a time (Leo, 2026-11-06: "we ought to have a
lot of that ui in react and not swift"). That plan was built (#37736, #37777) and reverted the next day
(#40756) on Lawrence's rule (2026-11-09: "imessage home lives in swift, chat ui lives in react,
acpmux/cmux-tui lives in rust"). The plan's text is gone from here so nobody builds it again; it is in this
file's history. Why it flipped, and the other forks decided since, are in the team's junction log
(cmuxterm-hq `decisions/junctions.md`).

What is left on this page is the one section that still describes what ships.

## Chat Colors

One chat's bubble and text colours, with a live preview. It opens as a small floating panel, one for
the app. Opening it for another chat switches the panel to that chat.

- **Preview.** A sample of their message ("How do these colors look?") and of yours ("Looks good to
  me!"), in the colours the chat would draw with, on the chat's page colour.
- **My Messages and Their Messages**, each with two rows:
  - **Bubble.** Default (a slashed circle), then the swatches, then Custom Color (the system colour
    panel).
  - **Text.** Automatic (readable on the bubble), white, black, then Custom Color.
- **Swatches.** Mine: Messages' blue first, then the colours Messages and the system use most
  (`#0A84FF #34C759 #AF52DE #FF2D55 #FF9500 #FFD60A #30B0C7 #8E8E93`). Theirs:
  `#E9E9EB #3B3B3D #D6EAFF #D9F7E0 #EADCF8 #FFE5CC #1C2A4A`.
- **Picking.** A pick is stored at once, and the open chat redraws as you pick. The selected swatch
  has an accent ring 3 px outside it.
- **Buttons.** Reset to Default is enabled only when the chat has colours of its own. Done (↩) closes
  the panel. Escape closes it too.
- **Width and order.** 340 pt wide. The panel's height follows its content, and nothing moves while
  you pick: the preview and every row keep their place, and only colours change.
- **Keys.** Full keyboard access tabs through the swatches; Space presses one.

It is AppKit: `HomeChatColorsPanel` and `HomeChatColorsView` (`CmuxNextHome/ChatColors/`), tested by
`HomeChatColorsPanelTests`. Each row's label sits in a 48 pt column beside its swatches.
