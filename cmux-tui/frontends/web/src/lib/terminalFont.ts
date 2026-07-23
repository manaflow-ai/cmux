export const fallbackTerminalFontStack = 'Menlo, "SFMono-Regular", Consolas, "Liberation Mono", monospace';

/** Build a CSS-safe family stack from server-owned Ghostty appearance metadata. */
export function terminalFontStack(fontFamily: string | null | undefined): string {
  const family = fontFamily?.trim();
  if (family === undefined || family.length === 0 || /[\u0000-\u001f\u007f]/u.test(family)) {
    return fallbackTerminalFontStack;
  }
  return `${JSON.stringify(family)}, ${fallbackTerminalFontStack}`;
}
