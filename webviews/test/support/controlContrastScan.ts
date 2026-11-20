// l10n-allow-file: browser audit diagnostics, not shipped UI.
// The page side of test/control-contrast-N.test.ts (driver: test/support/controlContrast.ts).
//
// User 2026-11-20, after the bookmark editor's More…/Remove read as nearly invisible: "we should do
// audit of all surfaces like this to make sure all buttons have proper contrasts in all
// themes/modes". The contrast is read from the pixels the browser painted, not from the CSS: every
// control is captured twice, once as drawn and once with its ink hidden (text and `currentColor` made
// transparent, SVG icons hidden), so each ink pixel is compared with the very pixel behind it. That
// counts opacity, blending, glass, a picture behind a see-through window and any fill the CSS cascade
// gives, which a stylesheet resolver cannot.
//
// Everything here runs inside the page (page.evaluate), so each export is self-contained: no imports,
// no closures over module state.

/** A rectangle in CSS pixels, relative to the viewport. */
export type Box = { x: number; y: number; w: number; h: number };

/** One control the scan measures. */
export type Control = {
  /** Its index; the element carries it as `data-contrast-audit`. */
  id: number;
  /** A stable name: tag, up to three classes, and the start of its text or label. */
  label: string;
  /** The kind of control: button, link, tab, menuitem, option, toggle or field. */
  role: string;
  /** Disabled (`:disabled`, `aria-disabled`): held to the legible floor, not the full minimum. */
  disabled: boolean;
  /** WCAG's large text (24 px, or 18.66 px bold): 3:1 instead of 4.5:1. */
  large: boolean;
  /** Its border box. */
  box: Box;
  /** The line boxes of the text that belongs to it (not to a control inside it). */
  text: Box[];
};

/** One reading of one control in one capture. */
export type Reading = {
  id: number;
  /** `text`: its own text; `icon`: any other ink in its box (SVG, mask icons, `currentColor` marks). */
  kind: "text" | "icon";
  /** WCAG 2 contrast of the ink against the pixel behind it (the 95th percentile over its ink pixels). */
  ratio: number;
  /** The ink and the ground of the pixel that gave `ratio`, as `#rrggbb`. */
  ink: string;
  ground: string;
  /** How many device pixels of ink there were. */
  pixels: number;
};

/** Marks every visible, unobstructed control in the viewport and returns their boxes. */
export function markControls(): Control[] {
  const SELECTOR = [
    "button",
    '[role="button"]',
    '[role="tab"]',
    '[role="menuitem"]',
    '[role="menuitemradio"]',
    '[role="menuitemcheckbox"]',
    '[role="option"]',
    '[role="switch"]',
    '[role="checkbox"]',
    '[role="radio"]',
    "a[href]",
    "summary",
    "select",
    'input[type="button"]',
    'input[type="submit"]',
  ].join(", ");
  const roleOf = (el: Element): string => {
    const role = el.getAttribute("role");
    if (role === "tab") return "tab";
    if (role?.startsWith("menuitem")) return "menuitem";
    if (role === "option") return "option";
    if (role === "switch" || role === "checkbox" || role === "radio") return "toggle";
    if (el.tagName === "A") return "link";
    if (el.tagName === "SELECT") return "field";
    return "button";
  };
  const all = [...document.querySelectorAll<HTMLElement>(SELECTOR)];
  for (const el of document.querySelectorAll("[data-contrast-audit]")) el.removeAttribute("data-contrast-audit");
  const controls: Control[] = [];
  const index = new Map<Element, number>();
  const shown = (el: Element): boolean => {
    for (let node: Element | null = el; node; node = node.parentElement) {
      const css = getComputedStyle(node);
      if (css.display === "none" || css.visibility === "hidden" || Number(css.opacity) < 0.05) return false;
    }
    return true;
  };
  for (const el of all) {
    const rect = el.getBoundingClientRect();
    if (rect.width < 4 || rect.height < 4) continue;
    const x = Math.max(0, rect.left),
      y = Math.max(0, rect.top);
    const right = Math.min(innerWidth, rect.right),
      bottom = Math.min(innerHeight, rect.bottom);
    if (right - x < 4 || bottom - y < 4) continue;
    if (!shown(el)) continue;
    // Covered by something else (a menu, a sheet): what is painted there is not this control.
    const hit = document.elementFromPoint((x + right) / 2, (y + bottom) / 2);
    if (!hit || !(el.contains(hit) || hit.contains(el))) continue;
    index.set(el, controls.length);
    const css = getComputedStyle(el);
    const size = Number.parseFloat(css.fontSize);
    const weight = Number.parseInt(css.fontWeight, 10) || 400;
    const words = (el.getAttribute("aria-label") || el.textContent || "").replace(/\s+/g, " ").trim().slice(0, 24);
    const classes = [...el.classList]
      .filter((name) => !/^(?:is-|has-)?(?:hover|active|focus|selected|open|pressed|on|off)$/.test(name))
      .slice(0, 3)
      .map((name) => `.${name}`)
      .join("");
    controls.push({
      id: controls.length,
      label: `${el.tagName.toLowerCase()}${classes}${words ? ` "${words}"` : ""}`,
      role: roleOf(el),
      disabled:
        el.matches(":disabled") ||
        el.closest('[aria-disabled="true"], fieldset:disabled, [inert]') !== null ||
        css.pointerEvents === "none",
      large: size >= 24 || (size >= 18.66 && weight >= 700),
      box: { x, y, w: right - x, h: bottom - y },
      text: [],
    });
    el.setAttribute("data-contrast-audit", String(controls.length - 1));
  }
  // Each text node belongs to its nearest control: a row button's text is not its inner button's.
  const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
  for (let node = walker.nextNode(); node; node = walker.nextNode()) {
    if (!node.textContent?.trim()) continue;
    const owner = node.parentElement?.closest(SELECTOR);
    const id = owner ? index.get(owner) : undefined;
    if (id === undefined) continue;
    const range = document.createRange();
    range.selectNodeContents(node);
    for (const r of range.getClientRects()) {
      const x = Math.max(0, r.left),
        y = Math.max(0, r.top);
      const w = Math.min(innerWidth, r.right) - x,
        h = Math.min(innerHeight, r.bottom) - y;
      if (w > 1 && h > 1) controls[id]!.text.push({ x, y, w, h });
    }
  }
  return controls;
}

/** Hides (or shows again) every control's ink: text, `currentColor` and SVG. Layout does not move. */
export function hideInk(hidden: boolean): void {
  const id = "contrast-audit-hide-ink";
  document.getElementById(id)?.remove();
  if (!hidden) return;
  const style = document.createElement("style");
  style.id = id;
  style.textContent = `
    *, *::before, *::after {
      color: transparent !important;
      -webkit-text-fill-color: transparent !important;
      text-shadow: none !important;
      text-decoration-color: transparent !important;
      caret-color: transparent !important;
    }
    svg { visibility: hidden !important; }`;
  document.head.append(style);
}

/**
 * Reads every control from two captures of the viewport (PNG data URLs at `scale` device pixels per
 * CSS pixel): `drawn` as painted, `bare` with the ink hidden. A pixel is ink where the two differ.
 */
export async function readControls(arg: {
  drawn: string;
  bare: string;
  scale: number;
  controls: Control[];
}): Promise<Reading[]> {
  const pixels = async (url: string): Promise<ImageData> => {
    const bitmap = await createImageBitmap(await (await fetch(url)).blob());
    const canvas = new OffscreenCanvas(bitmap.width, bitmap.height);
    const ctx = canvas.getContext("2d", { willReadFrequently: true })!;
    ctx.drawImage(bitmap, 0, 0);
    return ctx.getImageData(0, 0, bitmap.width, bitmap.height);
  };
  const [drawn, bare] = await Promise.all([pixels(arg.drawn), pixels(arg.bare)]);
  const linear = new Float64Array(256);
  for (let i = 0; i < 256; i++) {
    const c = i / 255;
    linear[i] = c <= 0.04045 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
  }
  const lum = (d: Uint8ClampedArray, o: number) =>
    0.2126 * linear[d[o]!]! + 0.7152 * linear[d[o + 1]!]! + 0.0722 * linear[d[o + 2]!]!;
  const hex = (d: Uint8ClampedArray, o: number) =>
    `#${[d[o]!, d[o + 1]!, d[o + 2]!].map((v) => v.toString(16).padStart(2, "0")).join("")}`;
  const width = drawn.width,
    height = drawn.height,
    s = arg.scale;
  // Which pixels this read has counted already (its line boxes may overlap): a generation per read.
  const mark = new Uint32Array(width * height);
  let generation = 0;
  const inside = (px: number, py: number, boxes: Box[]) =>
    boxes.some((b) => px >= b.x * s && px < (b.x + b.w) * s && py >= b.y * s && py < (b.y + b.h) * s);
  const read = (id: number, kind: "text" | "icon", region: Box[], skip: Box[]): Reading | null => {
    const found: { ratio: number; o: number }[] = [];
    generation += 1;
    for (const b of region) {
      const x0 = Math.max(0, Math.floor(b.x * s)),
        y0 = Math.max(0, Math.floor(b.y * s));
      const x1 = Math.min(width, Math.ceil((b.x + b.w) * s)),
        y1 = Math.min(height, Math.ceil((b.y + b.h) * s));
      for (let py = y0; py < y1; py++)
        for (let px = x0; px < x1; px++) {
          const p = py * width + px,
            o = p * 4;
          if (mark[p] === generation) continue;
          mark[p] = generation;
          const a = drawn.data,
            g = bare.data;
          if (Math.abs(a[o]! - g[o]!) + Math.abs(a[o + 1]! - g[o + 1]!) + Math.abs(a[o + 2]! - g[o + 2]!) <= 12)
            continue;
          if (skip.length && inside(px, py, skip)) continue;
          const l1 = lum(a, o),
            l2 = lum(g, o);
          found.push({ ratio: (Math.max(l1, l2) + 0.05) / (Math.min(l1, l2) + 0.05), o });
        }
    }
    if (found.length < (kind === "text" ? 8 : 12)) return null;
    found.sort((p, q) => p.ratio - q.ratio);
    const at = found[Math.floor(0.95 * (found.length - 1))]!;
    return {
      id,
      kind,
      ratio: Math.round(at.ratio * 100) / 100,
      ink: hex(drawn.data, at.o),
      ground: hex(bare.data, at.o),
      pixels: found.length,
    };
  };
  const readings: Reading[] = [];
  for (const control of arg.controls) {
    const text = control.text.length ? read(control.id, "text", control.text, []) : null;
    if (text) readings.push(text);
    // Ink of a control inside this one is that control's; its box is skipped.
    const inner = arg.controls.filter(
      (other) =>
        other.id !== control.id &&
        other.box.x >= control.box.x - 0.5 &&
        other.box.y >= control.box.y - 0.5 &&
        other.box.x + other.box.w <= control.box.x + control.box.w + 0.5 &&
        other.box.y + other.box.h <= control.box.y + control.box.h + 0.5,
    );
    const icon = read(control.id, "icon", [control.box], [...control.text, ...inner.map((other) => other.box)]);
    if (icon) readings.push(icon);
  }
  return readings;
}
