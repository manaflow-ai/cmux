/**
 * The diff viewer's two backgrounds (plans/cmux-next/windows.md, "Web theme";
 * surface-backgrounds.md, R48/R55).
 *
 * - `--cmux-diff-viewer-bg` is the shared page background,
 *   `--cmux-surface-background`: the theme color in an opaque window,
 *   transparent over a see-through window, or the surface's R55 override.
 *   Only `html` paints it; every other block is clear over it.
 * - `--cmux-diff-solid-bg` is the same backdrop composited onto the theme
 *   background at full alpha. File header bars (Lawrence: never
 *   transparent) and the files panel paint it, so scrolled code and rows
 *   never show through them, and it matches the page in an opaque window.
 *
 * CSS can not composite one translucent color onto another into a single
 * color value, and the tree needs a color (its truncation marker paints
 * with it), so the solid color is computed here and set on the root. It is
 * recomputed on every `cmux-theme` event (the host's theme payload) and
 * when the color scheme flips. Before this runs, styles.css falls back to
 * the opaque theme color.
 */
export type RGBA = { r: number; g: number; b: number; a: number };

/** Parses the color strings `getComputedStyle` returns (`rgb[a](...)`, `color(srgb ...)`). */
export function parseComputedColor(value: string): RGBA | null {
  const text = value.trim().toLowerCase();
  if (text === "transparent") {
    return { r: 0, g: 0, b: 0, a: 0 };
  }
  const rgb = text.match(/^rgba?\(\s*([\d.]+)[\s,]+([\d.]+)[\s,]+([\d.]+)(?:\s*[,/]\s*([\d.]+%?))?\s*\)$/);
  if (rgb) {
    return { r: Number(rgb[1]), g: Number(rgb[2]), b: Number(rgb[3]), a: alphaOf(rgb[4]) };
  }
  const srgb = text.match(/^color\(srgb\s+([\d.e-]+)\s+([\d.e-]+)\s+([\d.e-]+)(?:\s*\/\s*([\d.]+%?))?\s*\)$/);
  if (srgb) {
    return { r: Number(srgb[1]) * 255, g: Number(srgb[2]) * 255, b: Number(srgb[3]) * 255, a: alphaOf(srgb[4]) };
  }
  return null;
}

function alphaOf(raw: string | undefined): number {
  if (raw == null) {
    return 1;
  }
  const value = raw.endsWith("%") ? Number(raw.slice(0, -1)) / 100 : Number(raw);
  return Number.isFinite(value) ? Math.max(0, Math.min(1, value)) : 1;
}

/** `top` painted over the opaque `base` ("source over"), at full alpha. */
export function compositeOpaque(top: RGBA, base: RGBA): string {
  const channel = (front: number, back: number) => Math.round(front * top.a + back * (1 - top.a));
  return `rgb(${channel(top.r, base.r)}, ${channel(top.g, base.g)}, ${channel(top.b, base.b)})`;
}

/**
 * The solid bar color: `backdrop` over the theme color at full alpha. The
 * theme color is the host's surface token with its opacity dropped, else
 * the terminal theme background (`fallback`). Null when either is unknown.
 */
export function solidBackdropColor(backdrop: RGBA | null, token: RGBA | null, fallback: RGBA | null): string | null {
  const base = token != null && token.a > 0 ? token : fallback;
  if (backdrop == null || base == null) {
    return null;
  }
  return compositeOpaque(backdrop, { ...base, a: 1 });
}

/** Resolves `cssColor` (may use `var()`) to a parsed color through a probe element. */
function resolveColor(probe: HTMLElement, cssColor: string): RGBA | null {
  probe.style.backgroundColor = "";
  probe.style.backgroundColor = cssColor;
  return parseComputedColor(getComputedStyle(probe).backgroundColor);
}

/** Computes `--cmux-diff-solid-bg` from the current page background and theme color. */
export function updateSolidBackdrop(doc: Document = document): void {
  const probe = doc.createElement("span");
  probe.style.cssText = "position:absolute;width:0;height:0;visibility:hidden;pointer-events:none";
  (doc.body ?? doc.documentElement).append(probe);
  try {
    const backdrop = resolveColor(probe, "var(--cmux-diff-viewer-bg)");
    // The theme color itself: the host's surface token (its opacity
    // dropped), else the terminal theme background.
    const token = resolveColor(probe, "var(--cmux-surface-token, var(--cmux-diff-bg))");
    const fallback = resolveColor(probe, "var(--cmux-diff-bg)");
    const solid = solidBackdropColor(backdrop, token, fallback);
    if (solid == null) {
      doc.documentElement.style.removeProperty("--cmux-diff-solid-bg");
      return;
    }
    doc.documentElement.style.setProperty("--cmux-diff-solid-bg", solid);
  } finally {
    probe.remove();
  }
}

let installed = false;

/** Keeps `--cmux-diff-solid-bg` current. Call once when the page boots. */
export function installSolidBackdrop(win: Window = window): void {
  if (installed) {
    return;
  }
  installed = true;
  const update = () => updateSolidBackdrop(win.document);
  update();
  win.addEventListener("cmux-theme", update);
  win.matchMedia?.("(prefers-color-scheme: dark)").addEventListener?.("change", update);
}
