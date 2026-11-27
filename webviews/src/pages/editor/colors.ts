// CSS colors to the `#rrggbbaa` hex Monaco's theme takes. A `--cmux-editor-*` value may be any CSS
// color (`light-dark()`, `color-mix()`, `var()`); the engine resolves it on a probe element inside the
// editor (so the scheme and the user's theme.css apply) and this module reads the computed color.

/** `rgb()`/`rgba()`/`color(srgb ...)` as computed by WebKit or Chromium, to hex; null otherwise. */
export function computedColorToHex(computed: string): string | null {
  const value = computed.trim();
  const channel = (text: string, scale: number) => {
    const number = Number.parseFloat(text);
    if (!Number.isFinite(number)) return null;
    return Math.max(0, Math.min(255, Math.round(text.trim().endsWith("%") ? (number / 100) * 255 : number * scale)));
  };
  const alpha = (text: string | undefined) => {
    if (text === undefined) return 255;
    const number = Number.parseFloat(text);
    if (!Number.isFinite(number)) return 255;
    return Math.max(0, Math.min(255, Math.round((text.trim().endsWith("%") ? number / 100 : number) * 255)));
  };
  let rgba: number[] | null = null;
  const rgb = value.match(/^rgba?\(\s*([^,\s/]+)[\s,]+([^,\s/]+)[\s,]+([^,\s/)]+)(?:\s*[,/]\s*([^)\s]+))?\s*\)$/i);
  if (rgb) {
    const parts = [channel(rgb[1], 1), channel(rgb[2], 1), channel(rgb[3], 1)];
    if (parts.every((part) => part !== null)) rgba = [...(parts as number[]), alpha(rgb[4])];
  }
  const srgb = value.match(/^color\(\s*srgb\s+([^\s/]+)\s+([^\s/]+)\s+([^\s/)]+)(?:\s*\/\s*([^)\s]+))?\s*\)$/i);
  if (srgb) {
    const parts = [channel(srgb[1], 255), channel(srgb[2], 255), channel(srgb[3], 255)];
    if (parts.every((part) => part !== null)) rgba = [...(parts as number[]), alpha(srgb[4])];
  }
  if (!rgba) return null;
  return `#${rgba.map((part) => part.toString(16).padStart(2, "0")).join("")}`;
}

/** Resolves a CSS color value inside `scope` and returns it as hex, or null when it is not a color. */
export function cssColorToHex(value: string, scope: HTMLElement): string | null {
  const text = value.trim();
  if (!text) return null;
  if (text === "transparent") return "#00000000";
  if (/^#[0-9a-f]{3,8}$/i.test(text)) return text;
  const probe = scope.ownerDocument.createElement("span");
  probe.style.display = "none";
  probe.style.color = text;
  if (!probe.style.color) return null;
  scope.append(probe);
  try {
    return computedColorToHex(getComputedStyle(probe).color);
  } finally {
    probe.remove();
  }
}
