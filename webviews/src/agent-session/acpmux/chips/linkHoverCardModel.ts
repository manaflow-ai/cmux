/// `href`'s host, or `href` when it doesn't parse.
export function linkHost(href: string): string {
  try {
    return new URL(href).host;
  } catch {
    return href;
  }
}

/// A link's text with what never tells two lines apart taken off: case, a scheme, a leading `www.`,
/// a trailing slash and runs of white space.
function linkText(text: string): string {
  return text
    .trim()
    .toLowerCase()
    .replace(/^[a-z][\w+.-]*:\/\//, "")
    .replace(/^www\./, "")
    .replace(/\/+$/, "")
    .replace(/\s+/g, " ");
}

/// Whether a line under a hover card's title only repeats it (Leo 2026-11-22: the GitHub card
/// printed "owner/repo#7909" as its title and again as the link under it). Such a line is left out.
export function repeatsTitle(title: string | undefined, line: string | undefined): boolean {
  if (!title || !line) return false;
  return linkText(title) === linkText(line);
}
