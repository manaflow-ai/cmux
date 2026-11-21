// The content chip's data (composer/ContentChip.tsx): its label's parts and how it opens. Kept out of
// the component's module so that module exports only components (Fast Refresh).

/// One part of a chip's label row. The row shows its parts on one line that wraps only between
/// parts and draws only its first row, so with too little room the parts drop from the end, whole;
/// none is ever cut through a word. The first part (`name`) always shows.
export type ChipLabelPart = { part: string; text: string };

/// How a chip opened in place folds back (gallery agent-pane.attachment-chip, `collapse-*`):
/// `footer`, a bar under the content with a Collapse button at its end; `corner`, a Collapse pill in
/// the content's top-right corner; `chevron`, only a chevron in the face that flips.
export type ChipCollapse = "footer" | "corner" | "chevron";

/// How a chip opens its content: a viewer sheet over the pane, or in place under its face, folding
/// back by its collapse control.
export type ChipOpening = { kind: "sheet" } | { kind: "panel"; collapse: ChipCollapse };

/// Where the chip sits: the composer's strip, placed in the prompt's text, or in a sent message.
export type ChipHost = "strip" | "inline" | "sent";

/// An action in the opened view (a paste's Edit in Prompt and Keep as .txt): it closes the view,
/// then acts. `primary` is the sheet's solid button.
export type ChipAction = { id: string; label: string; className: string; primary?: boolean; onSelect(): void };
