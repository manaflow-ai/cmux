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
  /// Computed layout facts behind the numbers (display, grid placement, child lists): diagnostics.
  dom: Record<string, string>;
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
  const send = q(".acpmux-composer-box .acpmux-send");
  const foot = q(".acpmux-composer-foot");
  const mode = q(".acpmux-composer-foot .acpmux-access-trigger");
  const model = q(".acpmux-composer-foot .acpmux-model .acpmux-picker-button");
  /** The first of a chip's labels the reader sees (visible, drawn), or null. */
  const visibleOf = (chip: Element | null | undefined, selectors: string[]): Element | null => {
    if (!chip) return null;
    for (const selector of selectors)
      for (const element of chip.querySelectorAll(selector)) {
        if (getComputedStyle(element).visibility !== "visible") continue;
        if (element.getBoundingClientRect().width === 0) continue;
        return element;
      }
    return null;
  };
  const ring = q(".acpmux-composer-foot .acpmux-context-ring");
  const css = (element: Element | null | undefined, prop: string): string => {
    if (!element) return "none";
    return getComputedStyle(element).getPropertyValue(prop);
  };
  const kids = (element: Element | null | undefined): string =>
    element
      ? [...element.children].map((child) => `${child.tagName.toLowerCase()}.${child.className}`).join(" | ")
      : "";
  const chrome = q(".acpmux-composer-box > .acpmux-chrome-area");
  const bar = q(".acpmux-composer-box .acpmux-composer-bar");
  const plusRoot = q(".acpmux-composer-bar .acpmux-composer-plus");
  const fieldMenu = q(".acpmux-composer-box > .acpmux-composer-field-menu");
  const field = q(".acpmux-composer-box .acpmux-md-field");
  const actions = q(".acpmux-composer-box .acpmux-composer-actions");
  const dom: Record<string, string> = {
    boxClass: box?.className ?? "",
    boxDisplay: css(box, "display"),
    boxGridColumns: css(box, "grid-template-columns"),
    boxKids: kids(box),
    chromeClass: chrome?.className ?? "",
    chromeDisplay: css(chrome, "display"),
    chromeKids: kids(chrome),
    barClass: bar?.className ?? "",
    barDisplay: css(bar, "display"),
    barKids: kids(bar),
    fieldMenuDisplay: css(fieldMenu, "display"),
    plusRootClass: plusRoot?.className ?? "",
    plusRootDisplay: css(plusRoot, "display"),
    plusRootGridRow: css(plusRoot, "grid-row-start"),
    plusRootGridColumn: css(plusRoot, "grid-column-start"),
    fieldGridRow: css(field, "grid-row-start"),
    fieldGridColumn: `${css(field, "grid-column-start")} / ${css(field, "grid-column-end")}`,
    actionsGridRow: css(actions, "grid-row-start"),
    actionsGridColumn: css(actions, "grid-column-start"),
    actionsDisplay: css(actions, "display"),
    modeChipDisplay: css(mode, "display"),
    modeChipAlignItems: css(mode, "align-items"),
    modeChipHeight: css(mode, "height"),
    modeChipPadding: css(mode, "padding-top") + " " + css(mode, "padding-bottom"),
    modeLabelDisplay: css(q(".acpmux-composer-foot .acpmux-mode-text"), "display"),
    modeLabelPosition: css(q(".acpmux-composer-foot .acpmux-mode-text"), "position"),
    modeLabelTopBottom:
      css(q(".acpmux-composer-foot .acpmux-mode-text"), "top") +
      " " +
      css(q(".acpmux-composer-foot .acpmux-mode-text"), "bottom"),
    modeLabelMargin:
      css(q(".acpmux-composer-foot .acpmux-mode-text"), "margin-top") +
      " " +
      css(q(".acpmux-composer-foot .acpmux-mode-text"), "margin-bottom"),
    modeLabelPadding:
      css(q(".acpmux-composer-foot .acpmux-mode-text"), "padding-top") +
      " " +
      css(q(".acpmux-composer-foot .acpmux-mode-text"), "padding-bottom"),
    modeLabelLineHeight: css(q(".acpmux-composer-foot .acpmux-mode-text"), "line-height"),
    modeLabelFont: css(q(".acpmux-composer-foot .acpmux-mode-text"), "font-size"),
    modeChipKids: kids(mode),
    modelChipKids: kids(q(".acpmux-composer-foot .acpmux-model .acpmux-picker-button")),
    modelChipAlignItems: css(q(".acpmux-composer-foot .acpmux-model .acpmux-picker-button"), "align-items"),
    modelDetailMargin:
      css(q(".acpmux-composer-foot .acpmux-model-detail"), "margin-top") +
      " " +
      css(q(".acpmux-composer-foot .acpmux-model-detail"), "margin-bottom") +
      " pos " +
      css(q(".acpmux-composer-foot .acpmux-model-detail"), "position") +
      " top " +
      css(q(".acpmux-composer-foot .acpmux-model-detail"), "top"),
    plusGlyphDisplay: css(plusGlyph, "display"),
    plusGlyphVerticalAlign: css(plusGlyph, "vertical-align"),
  };
  return {
    dom,
    box: boxOf(box)!,
    plusButton: boxOf(plus),
    plusGlyph: boxOf(plusGlyph),
    placeholder: textOf(placeholderText),
    mic: boxOf(mic),
    micGlyph: boxOf(micGlyph),
    send: boxOf(send),
    foot: boxOf(foot),
    mode: boxOf(mode),
    // A label's own box (its line). The fit steps (composerLocation.css) hide a label that does not fit
    // with visibility hidden and keep its layout, so only a label the reader sees counts.
    modeText: boxOf(visibleOf(mode, [".acpmux-mode-text"])),
    modeGlyph: boxOf(mode?.querySelector("svg") ?? null),
    model: boxOf(model),
    modelText: boxOf(visibleOf(model, [".acpmux-model-detail", ".acpmux-model-name", ".acpmux-model-short"])),
    ring: boxOf(ring),
    ringGlyph: boxOf(ring?.querySelector("svg") ?? null),
  };
}
