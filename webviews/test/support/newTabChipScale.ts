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
