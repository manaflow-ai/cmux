// Measurable rules for a menu opened from a composer over glass (Leo, 2026-11-22: "we need to be
// writing out more constraints ... these are ules that we can follow and measure. i suppose we never
// set out to say \"contrast when there are context menus above\" etc for buttons for text for
// anything involving glass and such."). A gallery play or a browser test opens a menu and calls
// `menuConstraintFailures`; each broken rule comes back as one sentence with its numbers.
//
// 1. Direction: a menu opened from a composer control sits on the control's side away from the
//    composer's text field ("the things should usually if possible open away from the text input")
//    whenever that side has room for it (`expectAway`).
// 2. No overlap: the menu covers neither the text field nor any other drawn control's text (Lucas
//    saw the folder menu draw over the "Bypass permissions" chip), nor its own control.
// 3. Contrast over glass: the menu is translucent, so what is under it shows through. Its rows'
//    text, on every background between it and the menu (a selected row, a badge), must keep
//    `MENU_TEXT_CONTRAST` against the menu's fill laid over each surface under the menu (sampled on
//    a grid; the 32 px backdrop blur washes thin text strokes into the surface they sit on), the
//    lightest and the darkest alike.

/// WCAG AA body text.
export const MENU_TEXT_CONTRAST = 4.5;

/// The composer's text field (locationPopover.ts COMPOSER_FIELD).
const FIELD = ".acpmux-composer-box .ProseMirror, .acpmux-composer-box textarea, .nt-field";

/// Controls whose text a menu must not cover: the composer's buttons and chips.
const CONTROLS = ".acpmux-composer button, .nt-composer button, .acpmux-composer-strip button";

type Rgba = [number, number, number, number];
type Rgb = [number, number, number];

/// A computed CSS colour (`rgb()`, `rgba()` or `color(srgb ...)`) as 0-1 channels and alpha.
export function parseCssColor(value: string): Rgba | undefined {
  const srgb = value.match(/color\(srgb\s+([\d.e-]+)\s+([\d.e-]+)\s+([\d.e-]+)(?:\s*\/\s*([\d.e-]+%?))?\)/);
  if (srgb) return [Number(srgb[1]), Number(srgb[2]), Number(srgb[3]), alpha(srgb[4])];
  const rgb = value.match(/rgba?\(\s*([\d.]+)[,\s]+([\d.]+)[,\s]+([\d.]+)(?:\s*[,/]\s*([\d.]+%?))?\s*\)/);
  if (rgb) return [Number(rgb[1]) / 255, Number(rgb[2]) / 255, Number(rgb[3]) / 255, alpha(rgb[4])];
  return undefined;
}

function alpha(text: string | undefined): number {
  if (text === undefined) return 1;
  return text.endsWith("%") ? Number(text.slice(0, -1)) / 100 : Number(text);
}

/// `top` laid over the opaque `under`.
export function over(top: Rgba, under: [number, number, number]): [number, number, number] {
  const a = top[3];
  return [top[0] * a + under[0] * (1 - a), top[1] * a + under[1] * (1 - a), top[2] * a + under[2] * (1 - a)];
}

function luminance([r, g, b]: [number, number, number]): number {
  const lin = (c: number) => (c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4);
  return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b);
}

export function contrastRatio(a: [number, number, number], b: [number, number, number]): number {
  const [hi, lo] = [luminance(a), luminance(b)].sort((x, y) => y - x) as [number, number];
  return (hi + 0.05) / (lo + 0.05);
}

/// The least contrast `text` keeps on a menu filled with `fill` over each of `backdrops` (black and
/// white when none are given): the fill over each, then `layers` (backgrounds between the menu and the text,
/// outermost first, such as a badge's own fill), then the text (with its own alpha) over that.
export function worstContrastOverGlass(
  text: Rgba,
  fill: Rgba,
  layers: Rgba[] = [],
  backdrops: Rgb[] = [
    [0, 0, 0],
    [1, 1, 1],
  ],
): number {
  let worst = Infinity;
  for (const backdrop of backdrops) {
    let ground = over(fill, backdrop);
    for (const layer of layers) ground = over(layer, ground);
    worst = Math.min(worst, contrastRatio(over(text, ground), ground));
  }
  return worst;
}

/// The opaque colour of the page under `menu` at a grid of points: each point's stack of elements
/// outside the menu, composed from the first opaque background (or the canvas) up.
export function surfacesUnder(menu: Element): Rgb[] {
  const doc = menu.ownerDocument;
  const view = doc.defaultView!;
  const box = menu.getBoundingClientRect();
  const canvas =
    parseCssColor(view.getComputedStyle(doc.documentElement).backgroundColor) ??
    parseCssColor(view.getComputedStyle(doc.body).backgroundColor);
  const base: Rgb =
    canvas && canvas[3] >= 1
      ? [canvas[0], canvas[1], canvas[2]]
      : view.matchMedia("(prefers-color-scheme: dark)").matches
        ? [0, 0, 0]
        : [1, 1, 1];
  const out = new Map<string, Rgb>();
  for (const fx of [0.15, 0.5, 0.85])
    for (const fy of [0.15, 0.5, 0.85]) {
      const x = box.left + box.width * fx;
      const y = box.top + box.height * fy;
      const fills: Rgba[] = [];
      for (const el of doc.elementsFromPoint(x, y)) {
        if (menu.contains(el) || el.contains(menu)) continue;
        const bg = parseCssColor(view.getComputedStyle(el).backgroundColor);
        if (!bg || bg[3] <= 0) continue;
        fills.push(bg);
        if (bg[3] >= 1) break;
      }
      let ground = base;
      for (const fill of fills.reverse()) ground = over(fill, ground);
      out.set(ground.map((c) => c.toFixed(3)).join(","), ground);
    }
  return [...out.values()];
}

function intersects(a: DOMRect, b: DOMRect, slack = 1): boolean {
  return a.left < b.right - slack && b.left < a.right - slack && a.top < b.bottom - slack && b.top < a.bottom - slack;
}

const fmt = (r: DOMRect) => `${Math.round(r.top)}-${Math.round(r.bottom)}`;

export type MenuConstraintOptions = {
  /// The control that opened the menu.
  trigger: Element | null;
  /// Require the side away from the field (rule 1): the variant's window has room there.
  expectAway?: boolean;
};

/// The rules `menu` breaks, as sentences; empty when it keeps them all.
export function menuConstraintFailures(menu: Element, { trigger, expectAway = true }: MenuConstraintOptions): string[] {
  const failures: string[] = [];
  const doc = menu.ownerDocument;
  const view = doc.defaultView!;
  const box = menu.getBoundingClientRect();
  const composer = trigger?.closest("form.acpmux-composer, .nt-composer");
  const field = composer?.querySelector(FIELD) ?? undefined;
  const fieldBox = field?.getBoundingClientRect();
  const own = trigger?.getBoundingClientRect();

  // 1. Direction.
  if (expectAway && own && fieldBox && fieldBox.height > 0) {
    const above = (own.top + own.bottom) / 2 <= (fieldBox.top + fieldBox.bottom) / 2;
    const ok = above ? box.bottom <= own.top + 1 : box.top >= own.bottom - 1;
    if (!ok)
      failures.push(
        `direction: the menu (${fmt(box)}) should open ${above ? "up" : "down"}, away from the text field (${fmt(fieldBox)}), from its control (${fmt(own)})`,
      );
  }

  // 2. Overlap: the field, other controls' text, its own control.
  if (fieldBox && fieldBox.height > 0 && intersects(box, fieldBox))
    failures.push(`overlap: the menu (${fmt(box)}) covers the text field (${fmt(fieldBox)})`);
  if (own && intersects(box, own))
    failures.push(`overlap: the menu (${fmt(box)}) covers its own control (${fmt(own)})`);
  for (const control of doc.querySelectorAll(CONTROLS)) {
    if (control === trigger || trigger?.contains(control) || menu.contains(control)) continue;
    const label = control.textContent?.trim();
    if (!label) continue;
    const r = control.getBoundingClientRect();
    if (r.width <= 0 || r.height <= 0 || view.getComputedStyle(control).visibility === "hidden") continue;
    if (intersects(box, r)) failures.push(`overlap: the menu (${fmt(box)}) covers "${label.slice(0, 40)}" (${fmt(r)})`);
  }

  // 3. Contrast over glass: each row's text, through its own backgrounds, against the menu's fill over
  //    the lightest and darkest surface under it.
  const fill = parseCssColor(view.getComputedStyle(menu).backgroundColor);
  if (fill && fill[3] > 0) {
    const seen = new Set<string>();
    const backdrops = surfacesUnder(menu);
    const walker = doc.createTreeWalker(menu, NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      const text = node.textContent?.trim();
      const host = node.parentElement;
      if (!text || !host) continue;
      const style = view.getComputedStyle(host);
      if (style.visibility === "hidden" || host.getClientRects().length === 0) continue;
      // Placeholder-like hints are allowed the lower bar of large or incidental text (3:1).
      const bar = host.closest("[aria-disabled=true], [data-disabled], .ui-menu-hint") ? 3 : MENU_TEXT_CONTRAST;
      const color = parseCssColor(style.color);
      if (!color) continue;
      // Backgrounds drawn between the menu and the text (a row's hover, a badge's fill), outermost first.
      const layers: Rgba[] = [];
      for (let el: Element | null = host; el && el !== menu; el = el.parentElement) {
        const bg = parseCssColor(view.getComputedStyle(el).backgroundColor);
        if (bg && bg[3] > 0) layers.unshift(bg);
      }
      const ratio = worstContrastOverGlass(
        [color[0], color[1], color[2], color[3] * Number(style.opacity || 1)],
        fill,
        layers,
        backdrops,
      );
      const key = `${style.color}|${bar}`;
      if (ratio < bar && !seen.has(key)) {
        seen.add(key);
        failures.push(
          `contrast: "${text.slice(0, 30)}" (${style.color}) keeps ${ratio.toFixed(2)}:1 on the menu's glass (${view.getComputedStyle(menu).backgroundColor}) over the lightest or darkest surface under it; needs ${bar}:1`,
        );
      }
    }
  }
  return failures;
}
