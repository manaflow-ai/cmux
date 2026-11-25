// WCAG contrast of what a page draws, read from the colors it resolves (Leo, 2026-11-19: "you guys also
// need to watch for if there's light on light or dark on dark").
//
// For every element that draws text of its own (text nodes, a field's value or placeholder) and every
// drawn icon (an svg's strongest painted stroke or fill), it stacks the background colors of the element and
// its ancestors (across shadow roots), outermost opaque fill first, composites the ink over them at the
// opacity the element is drawn at, and takes the WCAG 2 contrast ratio. Minimums are WCAG AA: 4.5:1 for
// text, 3:1 for large text (>= 24px, or >= 18.66px at weight 700+) and 3:1 for icons (1.4.11, non-text).
// Disabled and inert controls are exempt, as WCAG exempts inactive components; elements that are clipped
// away, invisible or under 2px are not read.
//
// Limits (read from colors, not pixels): a background-image (gradient, wallpaper) or a backdrop blur
// is not composited; a line over one is marked `approx` so its reader knows the background is the
// nearest flat fill. Shared with look-addons.test.ts (#46049), which first wrote this walker.
import type { Page } from "playwright";

export const TEXT_MIN = 4.5;
export const LARGE_TEXT_MIN = 3;
export const NON_TEXT_MIN = 3;

export type ContrastLine = {
  /** Document-order index and the element's short path: stable between two reads of one page. */
  key: string;
  /** The element's short path (its classed ancestors, up to three), for a person to find it. */
  selector: string;
  kind: "text" | "placeholder" | "value" | "icon";
  /** The first 40 characters of its own text, or the icon's label. */
  text: string;
  /** The ink as drawn (over the background, at its opacity), as #rrggbb. */
  fg: string;
  /** The composited background under it, as #rrggbb. */
  bg: string;
  ratio: number;
  min: number;
  /** A background-image sits between the element and its nearest opaque fill: `bg` is approximate. */
  approx: boolean;
};

export type ContrastOptions = {
  /** Read only inside this selector's elements (default: the whole body). */
  within?: string;
  /** Read icons too (default true). */
  icons?: boolean;
};

/** Every drawn line of text and icon on `page`, with its contrast. */
export function readContrast(page: Page, options: ContrastOptions = {}): Promise<ContrastLine[]> {
  return page.evaluate(walkContrast, {
    within: options.within ?? "body",
    icons: options.icons ?? true,
    TEXT_MIN,
    LARGE_TEXT_MIN,
    NON_TEXT_MIN,
  });
}

/** The lines under their minimum. */
export function belowMinimum(lines: readonly ContrastLine[]): ContrastLine[] {
  return lines.filter((line) => line.ratio < line.min);
}

/** The lines `looked` draws under the minimum where `plain` did not, or lower than it did (#46049's rule). */
export function worseThan(plain: readonly ContrastLine[], looked: readonly ContrastLine[]): ContrastLine[] {
  const before = new Map(plain.map((line) => [line.key, line.ratio]));
  return looked.filter((line) => line.ratio < line.min && line.ratio < (before.get(line.key) ?? Infinity) - 0.05);
}

/** One failing pair, as a person reads it: element, text, foreground, background, ratio, required. */
export function formatPair(line: ContrastLine): string {
  return `${line.selector} ${line.kind} "${line.text}": fg ${line.fg} on bg ${line.bg}${line.approx ? " (over a background image)" : ""} = ${line.ratio}:1, needs ${line.min}:1`;
}

/** The failing pairs, one per distinct element, colors and ratio (a list of 30 identical rows reads as one). */
export function distinctPairs(lines: readonly ContrastLine[]): ContrastLine[] {
  const seen = new Set<string>();
  return lines.filter((line) => {
    const id = `${line.selector}|${line.kind}|${line.fg}|${line.bg}|${line.ratio}`;
    if (seen.has(id)) return false;
    seen.add(id);
    return true;
  });
}

type WalkArgs = { within: string; icons: boolean; TEXT_MIN: number; LARGE_TEXT_MIN: number; NON_TEXT_MIN: number };

/** Runs in the page: self-contained (Playwright sends its source). */
function walkContrast({ within, icons, TEXT_MIN, LARGE_TEXT_MIN, NON_TEXT_MIN }: WalkArgs): ContrastLine[] {
  const canvas = document.createElement("canvas");
  canvas.width = canvas.height = 1;
  const ctx = canvas.getContext("2d", { willReadFrequently: true })!;
  type Rgb = [number, number, number];
  type Rgba = [number, number, number, number];
  const parse = (css: string): Rgba => {
    const srgb = /^color\(srgb ([-\d.e]+) ([-\d.e]+) ([-\d.e]+)(?: \/ ([\d.e]+))?\)$/.exec(css);
    if (srgb) return [+srgb[1]!, +srgb[2]!, +srgb[3]!, srgb[4] === undefined ? 1 : +srgb[4]];
    const rgb = /^rgba?\(([\d.]+), ([\d.]+), ([\d.]+)(?:, ([\d.]+))?\)$/.exec(css);
    if (rgb) return [+rgb[1]! / 255, +rgb[2]! / 255, +rgb[3]! / 255, rgb[4] === undefined ? 1 : +rgb[4]];
    // oklab(), lab(), color-mix() results and the rest: the canvas converts them.
    ctx.clearRect(0, 0, 1, 1);
    ctx.fillStyle = "rgba(0, 0, 0, 0)";
    ctx.fillStyle = css;
    ctx.fillRect(0, 0, 1, 1);
    const [r, g, b, a] = ctx.getImageData(0, 0, 1, 1).data;
    return [r! / 255, g! / 255, b! / 255, a! / 255];
  };
  const clamp = (v: number) => Math.min(1, Math.max(0, v));
  const over = (top: Rgba, under: Rgb): Rgb => [
    clamp(top[0]) * top[3] + under[0] * (1 - top[3]),
    clamp(top[1]) * top[3] + under[1] * (1 - top[3]),
    clamp(top[2]) * top[3] + under[2] * (1 - top[3]),
  ];
  const luminance = (c: Rgb) => {
    const f = (v: number) => (v <= 0.04045 ? v / 12.92 : ((v + 0.055) / 1.055) ** 2.4);
    return 0.2126 * f(c[0]) + 0.7152 * f(c[1]) + 0.0722 * f(c[2]);
  };
  const hex = (c: Rgb) =>
    `#${c
      .map((v) =>
        Math.round(clamp(v) * 255)
          .toString(16)
          .padStart(2, "0"),
      )
      .join("")}`;
  const parentOf = (node: Element): Element | null =>
    node.parentElement ?? ((node.getRootNode() as ShadowRoot).host as Element | undefined) ?? null;
  const name = (el: Element) => {
    const classes = [...el.classList].filter((c) => !/^_|^css-|\d{3,}/.test(c)).slice(0, 2);
    return `${el.tagName.toLowerCase()}${classes.map((c) => `.${c}`).join("")}`;
  };
  const selectorOf = (el: Element) => {
    const parts = [name(el)];
    let node = parentOf(el);
    while (node && parts.length < 3 && node !== document.body) {
      if (node.classList.length) parts.unshift(name(node));
      node = parentOf(node);
    }
    return parts.join(" > ");
  };

  const roots = [...document.querySelectorAll(within)];
  const all: Element[] = [];
  const walk = (root: ParentNode) => {
    for (const el of root.querySelectorAll("*")) {
      all.push(el);
      if (el.shadowRoot) walk(el.shadowRoot);
    }
  };
  for (const root of roots) {
    all.push(root);
    walk(root);
  }
  const pageBg = parse(
    getComputedStyle(document.documentElement).getPropertyValue("--agent-page-bg").trim() ||
      getComputedStyle(document.documentElement).backgroundColor ||
      "#fff",
  );

  /** The background under `el`, its drawn opacity, and whether a background image sits in the stack. */
  const backdrop = (el: Element): { under: Rgb; opacity: number; approx: boolean } | null => {
    const fills: Rgba[] = [];
    const images: boolean[] = [];
    let opacity = 1;
    let clip: DOMRect | null = el.getBoundingClientRect();
    for (let node: Element | null = el; node; node = parentOf(node)) {
      const s = getComputedStyle(node);
      opacity *= +s.opacity;
      fills.unshift(parse(s.backgroundColor));
      images.unshift(s.backgroundImage !== "none");
      if (
        node !== el &&
        clip &&
        s.display !== "contents" &&
        (s.overflowX !== "visible" || s.overflowY !== "visible") &&
        node !== document.documentElement &&
        node !== document.body
      ) {
        const r = node.getBoundingClientRect();
        const x = Math.max(clip.x, r.x);
        const y = Math.max(clip.y, r.y);
        const w = Math.min(clip.right, r.right) - x;
        const h = Math.min(clip.bottom, r.bottom) - y;
        clip = w > 1 && h > 1 ? new DOMRect(x, y, w, h) : null;
      }
    }
    if (!clip || opacity < 0.05) return null;
    // The innermost opaque fill: what is under it never shows.
    let firstOpaque = fills.length - 1;
    while (firstOpaque >= 0 && fills[firstOpaque]![3] < 0.999) firstOpaque--;
    let under: Rgb = firstOpaque < 0 ? [pageBg[0], pageBg[1], pageBg[2]] : [1, 1, 1];
    for (const fill of fills.slice(Math.max(0, firstOpaque))) under = over(fill, under);
    const approx = images.slice(Math.max(0, firstOpaque)).some(Boolean);
    return { under, opacity, approx };
  };

  const lines: ContrastLine[] = [];
  const record = (
    index: number,
    el: Element,
    kind: ContrastLine["kind"],
    text: string,
    ink: Rgba,
    min: number,
    back: { under: Rgb; opacity: number; approx: boolean },
  ) => {
    if (ink[3] * back.opacity < 0.05) return;
    const drawn = over([ink[0], ink[1], ink[2], ink[3] * back.opacity], back.under);
    const [hi, lo] = [luminance(drawn), luminance(back.under)].sort((a, b) => b - a);
    const selector = selectorOf(el);
    lines.push({
      key: `${index} ${selector} ${kind}`,
      selector,
      kind,
      text: text.replace(/\s+/g, " ").slice(0, 40),
      fg: hex(drawn),
      bg: hex(back.under),
      ratio: Math.round(((hi! + 0.05) / (lo! + 0.05)) * 100) / 100,
      min,
      approx: back.approx,
    });
  };

  all.forEach((el, index) => {
    if (el.closest("[disabled], [aria-disabled='true'], [inert]")) return;
    if (el.closest("svg") && el.tagName.toLowerCase() !== "svg") return;
    const box = el.getBoundingClientRect();
    if (box.width < 2 || box.height < 2) return;
    const style = getComputedStyle(el);
    if (style.visibility !== "visible" || style.display === "none") return;
    const size = parseFloat(style.fontSize);
    const large = size >= 24 || (size >= 18.66 && +style.fontWeight >= 700);
    const textMin = large ? LARGE_TEXT_MIN : TEXT_MIN;
    const tag = el.tagName.toLowerCase();

    if (tag === "svg") {
      if (!icons || box.width < 6 || box.height < 6) return;
      const back = backdrop(el);
      if (!back) return;
      // Every shape that paints (its stroke, else its fill); the icon reads by its strongest one, so a
      // meter's faint track beside its arc is not the icon's color.
      let paint: Rgba | null = null;
      let best = -1;
      for (const shape of el.querySelectorAll("path, circle, rect, line, polyline, polygon, ellipse, use, text")) {
        const s = getComputedStyle(shape);
        if (s.display === "none" || s.visibility !== "visible") continue;
        let c: Rgba | null = null;
        if (s.stroke !== "none" && parseFloat(s.strokeWidth) > 0 && !s.stroke.startsWith("url(")) {
          const v = parse(s.stroke);
          c = [v[0], v[1], v[2], v[3] * +s.strokeOpacity * +s.opacity];
        } else if (s.fill !== "none" && !s.fill.startsWith("url(")) {
          const v = parse(s.fill);
          c = [v[0], v[1], v[2], v[3] * +s.fillOpacity * +s.opacity];
        }
        if (!c || c[3] < 0.05) continue;
        const drawn = over([c[0], c[1], c[2], c[3] * back.opacity], back.under);
        const [hi, lo] = [luminance(drawn), luminance(back.under)].sort((a, b) => b - a);
        const ratio = (hi! + 0.05) / (lo! + 0.05);
        if (ratio > best) [best, paint] = [ratio, c];
      }
      if (!paint) return;
      const label =
        el.getAttribute("aria-label") ||
        el.closest("[aria-label]")?.getAttribute("aria-label") ||
        el.closest("[title]")?.getAttribute("title") ||
        "(icon)";
      record(index, el, "icon", label, paint, NON_TEXT_MIN, back);
      return;
    }

    if (tag === "textarea" || tag === "input") {
      const field = el as HTMLTextAreaElement | HTMLInputElement;
      if (tag === "input" && !/^(text|search|email|url|tel|number|password|)$/.test(field.type)) return;
      const back = backdrop(el);
      if (!back) return;
      if (field.value)
        record(index, el, "value", field.value, parse(style.webkitTextFillColor || style.color), textMin, back);
      else if (field.placeholder) {
        const ph = getComputedStyle(el, "::placeholder");
        record(
          index,
          el,
          "placeholder",
          field.placeholder,
          [...parse(ph.color).slice(0, 3), parse(ph.color)[3] * +ph.opacity] as Rgba,
          textMin,
          back,
        );
      }
      return;
    }

    const own = [...el.childNodes]
      .filter((node) => node.nodeType === Node.TEXT_NODE)
      .map((node) => node.textContent ?? "")
      .join("")
      .trim();
    if (!own) return;
    const back = backdrop(el);
    if (!back) return;
    // What paints the glyphs: -webkit-text-fill-color wins over color. Transparent fill is gradient
    // or clipped text, which colors cannot measure.
    const ink = parse(style.webkitTextFillColor || style.color);
    if (ink[3] < 0.05 && style.backgroundClip === "text") return;
    record(index, el, "text", own, ink, textMin, back);
  });
  return lines;
}
