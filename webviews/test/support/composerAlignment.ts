// Shared measurement for the composer's alignment tests (composer-alignment-centers.test.ts and
// composer-alignment-measure.test.ts). Runs in the page: every control's drawn box and the
// centers of what it draws, in CSS pixels of the viewport.

export type Center = { left: number; right: number; top: number; bottom: number; cx: number; cy: number };

export type ComposerAlignment = {
  box: Center;
  /// The + button (its hit box) and the + glyph (its svg).
  plusButton: Center | null;
  plusGlyph: Center | null;
  /// The placeholder's drawn text (the caret's line in an empty prompt).
  placeholder: Center | null;
  /// The mic button and its glyph; Send's button when a draft shows it.
  mic: Center | null;
  micGlyph: Center | null;
  send: Center | null;
  /// The quiet row: the permission mode (button, its text, its shield), the model (button, its
  /// text), the context ring (box and glyph). Null where the row does not show them.
  foot: Center | null;
  mode: Center | null;
  modeText: Center | null;
  modeGlyph: Center | null;
  model: Center | null;
  modelText: Center | null;
  ring: Center | null;
  ringGlyph: Center | null;
};

/** Runs in the page. */
export function measureComposerAlignment(): ComposerAlignment {
  const boxOf = (element: Element | null | undefined): Center | null => {
    if (!element) return null;
    const rect = element.getBoundingClientRect();
    if (rect.width === 0 && rect.height === 0) return null;
    return {
      left: rect.left,
      right: rect.right,
      top: rect.top,
      bottom: rect.bottom,
      cx: (rect.left + rect.right) / 2,
      cy: (rect.top + rect.bottom) / 2,
    };
  };
  // The text's drawn box: the range over the element's text, so padding and the line box do not count.
  const textOf = (element: Element | null | undefined): Center | null => {
    if (!element) return null;
    const range = document.createRange();
    range.selectNodeContents(element);
    const rect = range.getBoundingClientRect();
    if (rect.width === 0) return null;
    return {
      left: rect.left,
      right: rect.right,
      top: rect.top,
      bottom: rect.bottom,
      cx: (rect.left + rect.right) / 2,
      cy: (rect.top + rect.bottom) / 2,
    };
  };
  const q = <T extends Element = HTMLElement>(selector: string): T | null => document.querySelector<T>(selector);
  const box = q(".acpmux-composer-box");
  const plus = q(".acpmux-composer-plus .acpmux-picker-button");
  const plusGlyph = plus?.querySelector("svg") ?? null;
  const placeholder = q(".acpmux-composer-box .acpmux-md-placeholder");
  const placeholderText = placeholder?.querySelector(".acpmux-md-placeholder-text") ?? placeholder;
  const mic = q(".acpmux-composer-box .acpmux-mic");
  const micGlyph = mic?.querySelector("svg") ?? null;
  const send = q(".acpmux-composer-box .acpmux-send:not(.acpmux-steer-now)");
  const foot = q(".acpmux-composer-foot");
  const mode = q(".acpmux-composer-foot .acpmux-access-trigger");
  const model = q(".acpmux-composer-foot .acpmux-model .acpmux-picker-button");
  const ring = q(".acpmux-composer-foot .acpmux-context-ring");
  return {
    box: boxOf(box)!,
    plusButton: boxOf(plus),
    plusGlyph: boxOf(plusGlyph),
    placeholder: textOf(placeholderText),
    mic: boxOf(mic),
    micGlyph: boxOf(micGlyph),
    send: boxOf(send),
    foot: boxOf(foot),
    mode: boxOf(mode),
    modeText: textOf(
      mode?.querySelector(".acpmux-mode-text") ?? mode?.querySelector(":scope > span:not(.acpmux-icon)"),
    ),
    modeGlyph: boxOf(mode?.querySelector("svg") ?? null),
    model: boxOf(model),
    modelText: textOf(
      q(".acpmux-composer-foot .acpmux-model .acpmux-model-detail") ??
        q(".acpmux-composer-foot .acpmux-model .acpmux-model-name"),
    ),
    ring: boxOf(ring),
    ringGlyph: boxOf(ring?.querySelector("svg") ?? null),
  };
}
