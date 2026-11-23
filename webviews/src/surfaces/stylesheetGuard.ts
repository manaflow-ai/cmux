// cmux.stylesheetGuard/1 (schemas/agent-pane/stylesheet-guard.json): a person's own theme.css is any CSS,
// applied after the surface's built-in styles, but it loads nothing by address. The same rule as the
// Rust `cmux_customize::community::fetches` (`cmux customize` status and apply, `cmux setup install`); both
// test suites read the schema's cases, so the two never drift.

/** Why `css` would load something by address, or undefined when it loads nothing. */
export function stylesheetFetches(css: string): string | undefined {
  let plain = "";
  let rest = css;
  for (let open = rest.indexOf("/*"); open >= 0; open = rest.indexOf("/*")) {
    plain += `${rest.slice(0, open)} `;
    const close = rest.indexOf("*/", open + 2);
    rest = close < 0 ? "" : rest.slice(close + 2);
  }
  plain += rest;
  const lower = plain.toLowerCase();
  if (lower.includes("\\")) return "it has a backslash escape";
  if (lower.includes("@import")) return "it has an @import";
  if (lower.includes("image-set(") || lower.includes("src(")) return "it loads an image or font by address";
  let search = lower;
  for (let at = search.indexOf("url("); at >= 0; at = search.indexOf("url(")) {
    const after = search.slice(at + 4);
    const inner = after
      .trimStart()
      .replace(/^["']+/, "")
      .trimStart();
    if (!inner.startsWith("data:")) return "it has a url() that is not a data: URL";
    search = after;
  }
  return undefined;
}

/**
 * The text a surface applies as the person's stylesheet: `css` itself, or, when it would load
 * something, the sheet already applied (`kept`), so a refused save leaves the last good look on
 * screen. `refused` hears why, once per refused text.
 */
export function guardedStylesheet(css: string, kept: string, refused: (why: string) => void): string {
  const why = stylesheetFetches(css);
  if (why === undefined) return css;
  refused(why);
  return kept;
}
