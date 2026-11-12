// The New Tab composer's chips as one set (test/newtab-chip-scale.test.ts): the folder and computer
// chips above the box and the permission and model chips under it. Each chip draws a leading glyph,
// a label and (most) a chevron; this reads their laid-out sizes so a test can hold them to one scale.
// It runs in the page (page.evaluate or `cmux browser eval`), so it carries no imports.

/** One chip's measured parts, in CSS px; null where the chip draws no such part. */
export type ChipMeasure = {
  chip: string;
  glyph: number | null;
  label: { size: number; weight: number } | null;
  chevron: number | null;
  /** The label's ink center minus the glyph's center (px; 0 is one line). */
  glyphOffset: number | null;
};

/** Reads every chip around the New Tab box. Pass it to page.evaluate as is. */
export function measureNewTabChips(): ChipMeasure[] {
  const square = (element: Element | null | undefined) => {
    if (!element) return null;
    const rect = element.getBoundingClientRect();
    return rect.width === 0 ? null : Math.round(Math.max(rect.width, rect.height) * 100) / 100;
  };
  const centerY = (element: Element | null | undefined) => {
    if (!element) return null;
    const rect = element.getBoundingClientRect();
    return rect.height === 0 ? null : (rect.top + rect.bottom) / 2;
  };
  const shown = (element: Element | null | undefined): element is Element => {
    if (!element) return false;
    const style = getComputedStyle(element);
    return style.display !== "none" && style.visibility !== "hidden" && element.getBoundingClientRect().width > 0;
  };
  const chips: Array<[string, Element | null]> = [
    ...[...document.querySelectorAll(".nt-above .acpmux-location-button")].map(
      (button, index) => [`location ${index + 1}`, button] as [string, Element],
    ),
    ["access", document.querySelector(".nt-foot .acpmux-access-trigger")],
    ["model", document.querySelector(".nt-foot .acpmux-model .acpmux-picker-button")],
  ];
  return chips
    .filter(([, button]) => shown(button))
    .map(([chip, button]) => {
      const parts = [...button!.children].filter(shown);
      const first = parts[0];
      // The leading glyph: an svg, a project badge's own svg or image, or the model's mark.
      const glyphElement =
        first && first.matches("svg, img") ? first : (first?.querySelector(":scope > svg, :scope > img") ?? null);
      const last = parts.at(-1);
      // The trailing chevron: an svg, or a ghost button's icon slot around one.
      const chevron =
        last && last !== first && (last.textContent ?? "").trim() === ""
          ? last.matches("svg")
            ? last
            : last.querySelector(":scope > svg")
          : null;
      const labelElement = parts.find((part) => !part.matches("svg, img") && (part.textContent ?? "").trim() !== "");
      const style = labelElement ? getComputedStyle(labelElement) : null;
      let ink: number | null = null;
      if (labelElement) {
        const range = document.createRange();
        range.selectNodeContents(labelElement);
        const rect = range.getBoundingClientRect();
        ink = (rect.top + rect.bottom) / 2;
      }
      const glyphCenter = centerY(glyphElement);
      return {
        chip,
        glyph: square(glyphElement),
        label: style ? { size: Number.parseFloat(style.fontSize), weight: Number(style.fontWeight) } : null,
        chevron: square(chevron),
        glyphOffset: ink !== null && glyphCenter !== null ? Math.round((ink - glyphCenter) * 100) / 100 : null,
      };
    });
}

/** The New Tab composer's ink and column edges, in CSS px and computed colors. */
export type NewTabEdges = {
  /** Each chip's resting label and glyph color, as `chip: color`. */
  inks: Record<string, string | null>;
  folderGlyphLeft: number | null;
  shieldGlyphLeft: number | null;
  folderInkLeft: number | null;
  plusInkLeft: number | null;
  folderLabelLeft: number | null;
  modeLabelLeft: number | null;
  sendInkRight: number | null;
  modelLabelRight: number | null;
};

/** Reads the chips' inks and the left and right column edges. Pass it to page.evaluate as is. */
export function measureNewTabEdges(): NewTabEdges {
  const q = (selector: string) => document.querySelector(selector);
  const box = (element: Element | null) => (element ? element.getBoundingClientRect() : null);
  const text = (element: Element | null) => {
    if (!element) return null;
    const range = document.createRange();
    range.selectNodeContents(element);
    const rect = range.getBoundingClientRect();
    return rect.width === 0 ? null : rect;
  };
  // A stroked glyph's ink: its path's bounds plus half its line, mapped from the viewBox.
  const ink = (svg: Element | null) => {
    if (!(svg instanceof SVGSVGElement)) return null;
    const rect = svg.getBoundingClientRect();
    const view = svg.viewBox.baseVal;
    const bounds = svg.getBBox();
    const scale = rect.width / (view && view.width ? view.width : rect.width);
    const stroke = Number.parseFloat(getComputedStyle(svg.querySelector("path") ?? svg).strokeWidth) || 0;
    const originX = view ? view.x : 0;
    return {
      left: rect.left + (bounds.x - originX - stroke / 2) * scale,
      right: rect.left + (bounds.x - originX + bounds.width + stroke / 2) * scale,
    };
  };
  const color = (element: Element | null) => (element ? getComputedStyle(element).color : null);
  const round = (value: number | null | undefined) =>
    value === null || value === undefined ? null : Math.round(value * 100) / 100;
  const folderButton = q(".nt-above .acpmux-location-button");
  const folderGlyph =
    folderButton?.querySelector(":scope > svg:first-child, :scope > .acpmux-project-badge:first-child > svg") ?? null;
  const shield = q(".nt-foot .acpmux-access-trigger > svg:first-child");
  const inks: Record<string, string | null> = {};
  for (const [index, button] of [...document.querySelectorAll(".nt-above .acpmux-location-button")].entries()) {
    inks[`location ${index + 1} label`] = color(button.querySelector(".acpmux-location-label"));
    inks[`location ${index + 1} glyph`] = color(button.querySelector(":scope > svg:first-child") ?? button);
  }
  inks["access label"] = color(q(".nt-foot .acpmux-mode-text"));
  inks["access glyph"] = color(shield);
  inks["model label"] = color(q(".nt-foot .acpmux-model-name"));
  const effort = q(".nt-foot .acpmux-model-detail");
  if (effort && text(effort)) inks["model effort"] = color(effort);
  return {
    inks,
    folderGlyphLeft: round(box(folderGlyph)?.left),
    shieldGlyphLeft: round(box(shield)?.left),
    folderInkLeft: round(ink(folderGlyph)?.left),
    plusInkLeft: round(ink(q(".nt-box .acpmux-composer-plus svg"))?.left),
    folderLabelLeft: round(text(q(".nt-above .acpmux-location-label"))?.left),
    modeLabelLeft: round(text(q(".nt-foot .acpmux-mode-text"))?.left),
    sendInkRight: round(ink(q(".nt-box .acpmux-send svg"))?.right),
    modelLabelRight: round(
      [...document.querySelectorAll(".nt-foot .acpmux-model .acpmux-picker-button > *")]
        .map((part) => text(part)?.right ?? Number.NEGATIVE_INFINITY)
        .reduce((a, b) => Math.max(a, b), Number.NEGATIVE_INFINITY),
    ),
  };
}
