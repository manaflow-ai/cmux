// Which reply text names a local path, for its chip (decision D4). The page only decides how a
// path looks; the host checks every open again (file.open: the pane's roots and a user gesture).
// A path on the deny list draws as plain text here, and the host refuses it as well.

/// A local path a link points at: absolute (`/Users/…/README.md`), from home (`~/…`), a `file://`
/// URL, or relative (`./notes.md`, `docs/a.md`), which the host resolves from the session's folder.
export function linkPath(href: string): string | undefined {
  if (isTemplatePath(safeDecode(href))) return undefined;
  if (/^file:\/\//i.test(href)) {
    try {
      const url = new URL(href);
      if (url.host && url.host !== "localhost") return undefined;
      return stripLine(decodeURIComponent(url.pathname));
    } catch {
      return undefined;
    }
  }
  if (href.startsWith("//") || href.startsWith("#") || href.startsWith("?") || /^[A-Za-z][A-Za-z0-9+.-]*:/.test(href))
    return undefined;
  const path = stripLine(safeDecode(href.split(/[?#]/)[0]!));
  return path || undefined;
}

/// An inline code span that is a path: absolute, from home, `./` or `../` relative, or a
/// `file://` URL, with either a file name with an extension or a trailing slash (`/tmp/app.log`,
/// `~/repo/src/`, also with a space as in `Application Support`), optionally with a
/// `:line[:col]` suffix. Shell commands, globs and flags stay code.
export function codePath(text: string): string | undefined {
  const value = text.trim();
  if (/^file:\/\//i.test(value)) {
    const path = linkPath(value);
    return path && isPathShape(path) ? path : undefined;
  }
  // `src/app.ts:12`: relative, as a compiler writes it, with its line (TEXT_LINK's last group).
  if (/^\.?[\w@+-]+\/(?:[\w.@+-]+\/)*[\w@+-][\w.@+-]*\.[A-Za-z0-9]{1,12}:\d+(?::\d+)?$/.test(value))
    return stripLine(value);
  if (!/^(?:~|\.{1,2})?\/[^\t\n`'"<>|*?$;&(){}[\]]+$/.test(value) || / -/.test(value)) return undefined;
  const path = stripLine(value);
  return isPathShape(path) ? path : undefined;
}

/// The one shape every written path has, in prose, code and links alike (D4): `/`, `~/`, `./` or
/// `../` first; a folder and a name (one name after `./`); and a file extension or a trailing
/// slash (a folder). `/usr`, `and/or` and `~/notes` stay text.
export function isPathShape(path: string): boolean {
  if (!/^(?:~|\.{1,2})?\//.test(path)) return false;
  const relative = /^\.{1,2}\//.test(path);
  const parts = path.split("/").filter((part) => part && part !== "~" && part !== "." && part !== "..");
  if (parts.length < (relative ? 1 : 2)) return false;
  return path.endsWith("/") || /\.[A-Za-z0-9]{1,12}$/.test(parts.at(-1)!);
}

/// A path or URL in plain reply text: `kind`, where it is and, for a path, the path to open (a
/// `file://` URL decoded, a line suffix dropped). Paths have the shape of `isPathShape` and no
/// spaces (prose has no quotes to bound one); a URL is http or https with a host. Trailing
/// sentence punctuation stays text.
/// `line`: the `:12` of `src/app.ts:12`, which the chip's label keeps.
export type TextLink = {
  kind: "path" | "url";
  start: number;
  end: number;
  value: string;
  path?: string;
  line?: number;
};

// Groups: a file URL; a path (a file with an extension and an optional line suffix, or a folder
// with its trailing slash that is not followed by more of a name); a web URL; a path relative to
// the session's folder written as a compiler does (`src/app.ts:12`), which needs its line suffix
// so `and/or.txt` stays prose. Its first folder has no dot inside, so `example.com/a.js:1` is not one.
// No link starts after a `+`: a long base64 run would retry a path at every `+/` (quadratic).
const TEXT_LINK =
  /(?<![\w/.:~@+-])(?:(file:\/\/(?:localhost)?\/[^\s<>()"'`]+)|((?:~|\.{1,2})?\/(?:[\w.@+-]+\/)+(?:[\w@+-][\w.@+-]*\.[A-Za-z0-9]{1,12}(?::\d+(?::\d+)?)?(?![\w/])|(?![\w@+-]|\.\w)))|(https?:\/\/[A-Za-z0-9][^\s<>()"'`]*)|(\.?[\w@+-]+\/(?:[\w.@+-]+\/)*[\w@+-][\w.@+-]*\.[A-Za-z0-9]{1,12}:\d+(?::\d+)?(?![\w/])))/g;

export function textLinks(text: string): TextLink[] {
  if (!text.includes("/")) return [];
  const out: TextLink[] = [];
  for (const match of text.matchAll(TEXT_LINK)) {
    let value = match[0];
    if (match[1] || match[3]) value = value.replace(/[.,;:!?*_]+$/, "");
    const start = match.index!;
    const end = start + value.length;
    if (match[3]) {
      if (/^https?:\/\/[^/?#]*[A-Za-z0-9]/.test(value)) out.push({ kind: "url", start, end, value });
      continue;
    }
    if (match[4]) {
      out.push({ kind: "path", start, end, value, path: stripLine(value), line: lineOf(value) });
      continue;
    }
    const path = match[1] ? linkPath(value) : stripLine(value);
    const line = lineOf(value);
    if (path && isPathShape(path)) out.push({ kind: "path", start, end, value, path, ...(line ? { line } : {}) });
  }
  return out;
}

/// The line of a `:12` or `:12:4` suffix.
function lineOf(value: string): number | undefined {
  const match = /:(\d+)(?::\d+)?$/.exec(value);
  return match ? Number(match[1]) : undefined;
}

/// A raster image the pane draws as a thumbnail: PNG, JPEG, GIF or WebP, by file extension.
const IMAGE_FILE = /\.(?:png|jpe?g|gif|webp)$/i;

export function isImagePath(path: string): boolean {
  return IMAGE_FILE.test(path) && !isTemplatePath(path);
}

/// A path that is a template or placeholder, not a file: it holds `${`, `{{`, `<` or `>`, or a glob
/// `*` (`/src/${variant}-320.png`, `{{name}}.md`, `<file>.png`, `out/*.png`), as code or a command
/// line spells one. It stays plain text: no chip, no thumbnail, no Open (Leo, 2026-10-31: "THE OPEN
/// BUTTON DOESN'T WORK" on `${variant}-320.png`).
export function isTemplatePath(path: string): boolean {
  return /\$\{|\{\{|[<>*]/.test(path);
}

/// An https address of a raster image (its path ends in an image extension), such as a PR's media
/// on raw.githubusercontent.com.
export function isImageUrl(url: string): boolean {
  try {
    const parsed = new URL(url);
    return parsed.protocol === "https:" && IMAGE_FILE.test(parsed.pathname);
  } catch {
    return false;
  }
}

/// The path without a `:12` or `:12:4` line suffix (the open takes the file).
function stripLine(path: string): string {
  return path.replace(/:\d+(?::\d+)?$/, "");
}

function safeDecode(text: string): string {
  try {
    return decodeURIComponent(text);
  } catch {
    return text;
  }
}

/// Folders under a home folder that hold credentials, and secret file names (D4).
const DENIED_FOLDER = /\/(?:\.ssh|\.gnupg|Library\/Keychains|\.aws|\.config\/gh)(?:\/|$)/;

/// Whether `path` is on the deny list: plain text, no action.
export function isDeniedPath(path: string): boolean {
  const name = (path.replace(/\/+$/, "").split("/").at(-1) ?? "").toLowerCase();
  return DENIED_FOLDER.test(path) || name.endsWith(".pem") || name.endsWith(".key") || name.startsWith(".env");
}

/// The chip's name: the last component (a folder keeps its slash off).
export function pathName(path: string): string {
  const trimmed = path.replace(/\/+$/, "");
  return trimmed.split("/").at(-1) || path;
}

/// Where `file.open` shows the file: always a tab of the pane, which is cmux's file pages (the
/// markdown page for Markdown, the code editor page for any other text, a preview for images and
/// PDFs). They show a file as text and never run it, so a page type is safe there too.
export function openTarget(_path: string): "tab" {
  return "tab";
}
