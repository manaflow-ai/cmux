// The prompt's words on the composer controls' centre line, at every density (cmux#51039; the person,
// 2026-11-22: "can we make sure that the text in the input box is vertically centered perfectly. make
// sure that this is the case for all density types as well").
//
// composerLocation.css centres the prompt's line box on +, Stop and the mic, then drops it by
// `--acpmux-text-drop` so the words' ink, not their line box, sits there. Its fallback (the font size
// over 14) is exact at 14 px, but the engine rounds a font's ascent and descent to whole pixels, so at
// the other densities' sizes the capitals' middle landed up to half a pixel low. This measures, in the
// engine that draws the prompt, where its font puts the baseline in one line of its line height, and
// writes the drop that puts the middle of the cap height on the line box's centre, which is the
// controls' centre. test/hat-composer-icon-grid.test.ts measures it.

const PROPERTY = "--acpmux-text-drop";

/// How far to drop a line box so the middle of its capitals sits on its centre: `baseline` is the
/// baseline's distance from the line box's top, `capHeight` the font's capital height.
export function capCenterDrop({
  lineHeight,
  baseline,
  capHeight,
}: {
  lineHeight: number;
  baseline: number;
  capHeight: number;
}): number {
  return lineHeight / 2 - (baseline - capHeight / 2);
}

/** Keeps `--acpmux-text-drop` on the grid box around `field` centring its words; returns the cleanup. */
export function followTextCenter(field: HTMLElement): (() => void) | undefined {
  const box = field.closest<HTMLElement>(".acpmux-composer-box[data-composer-grid]");
  const doc = field.ownerDocument;
  const view = doc.defaultView;
  if (!box || !view || typeof ResizeObserver !== "function") return undefined;
  let last = "";
  const measure = () => {
    if (!field.isConnected) return;
    // The words' own element: the editor inside the field when there is one.
    const text = field.querySelector<HTMLElement>("[contenteditable]") ?? field;
    const style = view.getComputedStyle(text);
    const lineHeight = Number.parseFloat(style.lineHeight);
    const context = doc.createElement("canvas").getContext("2d");
    if (!Number.isFinite(lineHeight) || !context) return;
    const font = `${style.fontStyle} ${style.fontWeight} ${style.fontSize} ${style.fontFamily}`;
    context.font = font;
    const capHeight = context.measureText("H").actualBoundingBoxAscent;
    if (!(capHeight > 0)) return;
    // One line of the prompt's font and line height, out of sight; a zero-size box on its baseline.
    const line = doc.createElement("div");
    line.setAttribute("aria-hidden", "true");
    line.style.cssText = `position:absolute;left:0;top:0;visibility:hidden;pointer-events:none;white-space:pre;margin:0;padding:0;border:0;font:${font};line-height:${style.lineHeight};`;
    const mark = doc.createElement("span");
    mark.style.cssText = "display:inline-block;width:0;height:0;vertical-align:baseline;";
    line.append("H", mark);
    box.append(line);
    const baseline = mark.getBoundingClientRect().top - line.getBoundingClientRect().top;
    line.remove();
    const drop = capCenterDrop({ lineHeight, baseline, capHeight });
    if (!Number.isFinite(drop)) return;
    const value = `${drop.toFixed(3)}px`;
    if (value === last && box.style.getPropertyValue(PROPERTY) === value) return;
    last = value;
    box.style.setProperty(PROPERTY, value);
  };
  // A density or text size change resizes the field (its line height is its height); a web font
  // arriving changes the metrics without one.
  const observer = new ResizeObserver(measure);
  observer.observe(field);
  const fonts = doc.fonts;
  fonts?.addEventListener?.("loadingdone", measure);
  void fonts?.ready?.then(measure);
  view.addEventListener("cmux-ui-scale-change", measure);
  measure();
  return () => {
    observer.disconnect();
    fonts?.removeEventListener?.("loadingdone", measure);
    view.removeEventListener("cmux-ui-scale-change", measure);
    box.style.removeProperty(PROPERTY);
  };
}
