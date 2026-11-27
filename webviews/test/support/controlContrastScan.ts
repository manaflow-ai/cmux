// l10n-allow-file: browser audit diagnostics, not shipped UI.
// The page side of test/control-contrast-N.test.ts (driver: test/support/controlContrast.ts).
//
// User 2026-11-20, after the bookmark editor's More…/Remove read as nearly invisible: "we should do
// audit of all surfaces like this to make sure all buttons have proper contrasts in all
// themes/modes". The contrast is read from the pixels the browser painted, not from the CSS: every
// control is captured twice, once as drawn and once with its ink hidden (text made clear, SVG icons and
// marks hidden, everything drawn in `currentColor` that is not ink left as it is: hideInk), so each
// ink pixel is compared with the very pixel behind it (an icon's pixels only inside the boxes of the
// ink hideInk hid). That
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
  // A control in a scroll edge's fade (a mask on a container: the thread minimap's list, a scrolled
  // sidebar) is faded on purpose while it scrolls out; it reads once it scrolls in. Within a quarter of
  // the container's side, at most 48 px, of a masked container's edge is the fade.
  const inFade = (el: Element, rect: DOMRect): boolean => {
    for (let node = el.parentElement; node; node = node.parentElement) {
      const css = getComputedStyle(node);
      const mask =
        css.maskImage && css.maskImage !== "none" ? css.maskImage : css.getPropertyValue("-webkit-mask-image");
      if (!mask || mask === "none" || !mask.includes("gradient")) continue;
      // A gradient runs top to bottom unless it says left or right: the fade is on that axis only.
      const across = /to (?:left|right)\b/.test(mask);
      const box = node.getBoundingClientRect();
      const dx = Math.min(48, box.width / 4),
        dy = Math.min(48, box.height / 4);
      if (
        across
          ? rect.left < box.left + dx || rect.right > box.right - dx
          : rect.top < box.top + dy || rect.bottom > box.bottom - dy
      )
        return true;
    }
    return false;
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
    if (inFade(el, rect)) continue;
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

/**
 * Hides (or shows again) every control's ink: its text, its SVG icons and its marks. Layout does not move.
 *
 * `currentColor` is never changed: a border, a hover pill or a 7% wash drawn in it is the control's
 * ground, not its ink, so it stays as painted and the ink is read against it. Text goes clear through
 * `-webkit-text-fill-color` (pseudo-element text too), an SVG hides, and so does a mark: a mask icon
 * (a leaf element's mask, or its `::before`/`::after`'s; a mask on an element with children is a fade,
 * as the thread minimap's list has, not an icon) or an empty element of at most 32 px a side that
 * paints a fill (a tick, a dot, a bar). A small switch, checkbox or radio hides whole: what WCAG 1.4.11
 * asks of it is its track or box against the ground, not its thumb against its own track. An agent's
 * brand mark in its owner's colors (`svg.agent-mark`, the "brand" logo style) is a logo, which WCAG
 * exempts: it stays drawn.
 *
 * Returns the boxes of the ink it hid (CSS pixels): a control's icon reading counts only the pixels in
 * them, so a glass layer that blurs again once the text under it goes clear is not read as ink.
 */
export function hideInk(hidden: boolean): Box[] {
  const id = "contrast-audit-hide-ink";
  const mark = "data-contrast-audit-mark";
  document.getElementById(id)?.remove();
  for (const el of document.querySelectorAll(`[${mark}]`)) el.removeAttribute(mark);
  if (!hidden) return [];
  const boxes: Box[] = [];
  const keep = (el: Element) => {
    const r = el.getBoundingClientRect();
    if (r.width > 0 && r.height > 0) boxes.push({ x: r.left - 1, y: r.top - 1, w: r.width + 2, h: r.height + 2 });
  };
  const toggle = '[role="switch"], [role="checkbox"], [role="radio"], input[type="checkbox"], input[type="radio"]';
  const masked = (css: CSSStyleDeclaration) =>
    (css.maskImage !== "none" && css.maskImage !== "") ||
    (css.getPropertyValue("-webkit-mask-image") || "none") !== "none";
  const paints = (css: CSSStyleDeclaration) =>
    (css.backgroundColor !== "rgba(0, 0, 0, 0)" && css.backgroundColor !== "transparent") ||
    css.backgroundImage !== "none";
  for (const el of document.querySelectorAll<HTMLElement>("body *")) {
    if (el instanceof SVGElement) continue;
    const css = getComputedStyle(el);
    const parts: string[] = [];
    const rect = el.getBoundingClientRect();
    const small = rect.width <= 32 && rect.height <= 32 && rect.width > 0 && rect.height > 0;
    const smallToggle = el.matches(toggle) && rect.width <= 48 && rect.height <= 32 && rect.width > 0;
    if (
      smallToggle ||
      (masked(css) && el.children.length === 0) ||
      (el.childNodes.length === 0 && small && paints(css))
    )
      parts.push("self");
    for (const pseudo of ["::before", "::after"] as const) {
      const p = getComputedStyle(el, pseudo);
      if (p.content === "none" || p.content === "normal") continue;
      if (masked(p)) parts.push(pseudo.slice(2));
    }
    if (parts.length) {
      el.setAttribute(mark, parts.join(" "));
      keep(el);
    }
  }
  for (const svg of document.querySelectorAll("svg:not(.agent-mark)")) keep(svg);
  const style = document.createElement("style");
  style.id = id;
  style.textContent = `
    *, *::before, *::after {
      -webkit-text-fill-color: transparent !important;
      text-shadow: none !important;
      text-decoration-color: transparent !important;
      caret-color: transparent !important;
    }
    svg:not(.agent-mark) { visibility: hidden !important; }
    [${mark}~="self"] { visibility: hidden !important; }
    [${mark}~="before"]::before, [${mark}~="after"]::after { visibility: hidden !important; }`;
  document.head.append(style);
  return boxes;
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
  /** The boxes of the hidden ink (hideInk's answer): only their pixels count as icon ink. */
  ink: Box[];
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
  const inked = new Uint8Array(width * height);
  for (const b of arg.ink) {
    const x0 = Math.max(0, Math.floor(b.x * s)),
      y0 = Math.max(0, Math.floor(b.y * s));
    const x1 = Math.min(width, Math.ceil((b.x + b.w) * s)),
      y1 = Math.min(height, Math.ceil((b.y + b.h) * s));
    for (let py = y0; py < y1; py++) inked.fill(1, py * width + x0, py * width + x1);
  }
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
          if (kind === "icon" && !inked[p]) continue;
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
