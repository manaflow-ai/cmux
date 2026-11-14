/// More than this many lines, or characters, and a Chief prompt opens collapsed.
const COLLAPSED_LINES = 6;
const COLLAPSED_CHARS = 600;

/// Whether a prompt is long enough to open collapsed.
export const isLongPrompt = (text: string) =>
  text.length > COLLAPSED_CHARS || text.split("\n").length > COLLAPSED_LINES;
