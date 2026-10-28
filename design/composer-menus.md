# Composer project and environment menus

The project and environment controls in the composer share one menu contract. Their glass and
colour tokens remain those of the composer; rows use one 32 px rhythm, one search inset, and the
same columns: icon or kind glyph, primary and secondary text, trailing status or branch affordance,
then selection check.

Menus open below their trigger so they stay away from the transcript. The shared placement rule
chooses below when it fits, and flips above only when the available space below is smaller than the
menu and the space above is greater. The chosen side is stable while filtering so rows never jump.

The project list leads with the current or most recently supplied project. Repository worktrees are
grouped under their repository; scratch and temporary folders stay out of the initial list unless
selected, and a search for their path or name surfaces them. This uses structural paths and never
arbitrary-name filtering. A project avatar or repository mark is shown when available. Otherwise a
quiet monogram has no tile and does not compete with the name.

The environment list leads with the current machine. Local machines use a laptop glyph, SSH hosts a
terminal/server glyph, and cloud machines a cloud glyph. Section headers, search, secondary state,
keyboard selection, and the scrollbar use the same columns and row height as projects.

Gallery states cover three, eight, and fifteen project rows plus local, SSH, and cloud environments.
The selected layout is this shared-column version because it keeps the name column stable while
preserving readable secondary details and the current check in both light and dark themes.
