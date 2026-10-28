// The text a cold New Tab page's native stand-in field took while the page loaded (AgentPaneView+FieldStandIn.swift,
// NewTabFieldSeed): the host dispatches it once, when this page's field has focus.
export const NEW_TAB_SEED_EVENT = "acpmux-newtab-seed";

export type FieldSeed = {
  text: string;
  /// UTF-16 offsets of `text`, as `setSelectionRange` takes them.
  selectionStart: number;
  selectionEnd: number;
  /// Return was pressed in the stand-in.
  submit: boolean;
};

/// The seed in an event's detail, or undefined when it is not one; the selection is clamped to the text.
export function parseFieldSeed(detail: unknown): FieldSeed | undefined {
  if (typeof detail !== "object" || detail === null) return undefined;
  const { text, selectionStart, selectionEnd, submit } = detail as Record<string, unknown>;
  if (typeof text !== "string" || typeof selectionStart !== "number" || typeof selectionEnd !== "number")
    return undefined;
  const clamp = (at: number) => Math.max(0, Math.min(text.length, Math.trunc(at)));
  const start = clamp(selectionStart);
  return { text, selectionStart: start, selectionEnd: Math.max(start, clamp(selectionEnd)), submit: submit === true };
}
