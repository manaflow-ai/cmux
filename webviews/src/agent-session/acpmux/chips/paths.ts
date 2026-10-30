// Which reply text names a local path, for its chip (decision D4). The page only decides how a
// path looks; the host checks every open again (file.open: the pane's roots and a user gesture).
// A path on the deny list draws as plain text here, and the host refuses it as well.

import { pathLocation, type ReplyPath } from "./pathLocation";

/// A local path a link points at: absolute (`/Users/…/README.md`), from home (`~/…`), a `file://`
/// URL, or relative (`./notes.md`, `docs/a.md`), which the host resolves from the session's folder.
export function linkPath(href: string): string | undefined {
  return linkReplyPath(href)?.path;
}

export function linkReplyPath(href: string): ReplyPath | undefined {
  if (/^file:\/\//i.test(href)) {
    try {
      const url = new URL(href);
      if (url.host && url.host !== "localhost") return undefined;
      return pathLocation(decodeURIComponent(url.pathname) + (/^#L\d+(?:C\d+|-L\d+)?$/.test(url.hash) ? url.hash : ""));
    } catch {
      return undefined;
    }
  }
  if (
    href.startsWith("//") ||
    href.startsWith("#") ||
    href.startsWith("?") ||
    (/^[A-Za-z][A-Za-z0-9+.-]*:/.test(href) && !/^[^:]+\.[A-Za-z0-9]+:\d/.test(href))
  )
    return undefined;
  const hash = href.indexOf("#");
  const pathname = (hash < 0 ? href : href.slice(0, hash)).split("?")[0]!;
  const fragment = hash < 0 ? "" : href.slice(hash);
  const target = pathLocation(safeDecode(pathname) + (/^#L\d+(?:C\d+|-L\d+)?$/.test(fragment) ? fragment : ""));
  // Only a bare name is ambiguous (`example.com:8080`); a link with a folder is a file.
  if (target.location && !target.path.includes("/") && !isFileLocation(target)) return undefined;
  return target.path ? target : undefined;
}

/// An inline code span that is a path: absolute, from home, `./` or `../` relative, or a
/// `file://` URL, with either a file name with an extension or a trailing slash (`/tmp/app.log`,
/// `~/repo/src/`, also with a space as in `Application Support`), optionally with a
/// `:line[:col]` suffix. Shell commands, globs and flags stay code.
export function codePath(text: string): string | undefined {
  return codeReplyPath(text)?.path;
}

export function codeReplyPath(text: string): ReplyPath | undefined {
  const value = text.trim();
  if (/^file:\/\//i.test(value)) {
    const target = linkReplyPath(value);
    return target && isPathShape(target.path) ? target : undefined;
  }
  if (/^[\w+.-]+:\/\//.test(value) || /[\t\n`'"<>|*?$;&(){}[\]]| -/.test(value)) return undefined;
  const target = pathLocation(value);
  if (!isFileLocation(target)) return undefined;
  if (target.path.includes("/") || target.location) return target;
  // A bare name (`test.py`, also `console.log`) is a chip only when the host finds that file in
  // the chat's folders; until then, and when it does not, it stays code.
  return { ...target, bare: true };
}

/// A file name with an extension, optionally inside a relative, absolute or home folder, or
/// a folder with a trailing slash. `/usr`, `and/or` and `~/notes` stay text.
export function isPathShape(path: string): boolean {
  if (
    !/^(?:~|\.{1,2})?\//.test(path) &&
    !/^\.?[\w@+-]+\//.test(path) &&
    !/^[\w@+-][\w.@+-]*\.[A-Za-z0-9]{1,12}$/.test(path)
  )
    return false;
  if (!path.includes("/") && !/\.[A-Za-z0-9]*[A-Za-z][A-Za-z0-9]*$/.test(path)) return false;
  const relative = /^\.{1,2}\//.test(path);
  const parts = path.split("/").filter((part) => part && part !== "~" && part !== "." && part !== "..");
  if (parts.length < (relative || (!path.startsWith("/") && !path.startsWith("~/")) ? 1 : 2)) return false;
  return path.endsWith("/") || /\.[A-Za-z0-9]{1,12}$/.test(parts.at(-1)!);
}

/// A path with no folder (`next-sync.py`): the host may have to search the chat's folders for it,
/// so it is asked apart from other paths and is no chip until the host has found it.
export function isNameOnlyPath(path: string): boolean {
  return !path.includes("/") && !path.startsWith("~");
}

/// A path or URL in plain reply text: `kind`, where it is and, for a path, the path to open (a
/// `file://` URL decoded, its parsed line location). Paths have the shape of `isPathShape` and no
/// spaces (prose has no quotes to bound one); a URL is http or https with a host. Trailing
/// sentence punctuation stays text.
export type TextLink = {
  kind: "path" | "url";
  start: number;
  end: number;
  value: string;
  path?: string;
  location?: ReplyPath["location"];
  suffix?: string;
};

// Groups: a file URL; a web URL; a path (a file with an extension and an optional line suffix, or
// a folder with its trailing slash that is not followed by more of a name). A path never starts
// right after `$` (`$HOME/notes.md`, `$5/$10`). A relative path's first folder has no dot inside,
// so `example.com/a.js:1` is not one. No link starts after a `+`, and one folder run ends in a
// file or a folder's end: a long base64 run must not backtrack (quadratic).
const TEXT_LINK =
  /(?<![\w/\\.:~@$+-])(?:(file:\/\/(?:localhost)?\/[^\s<>()"'`]+)|(https?:\/\/[A-Za-z0-9][^\s<>()"'`]*)|((?:(?:~|\.{1,2})?\/|\.?[\w@+-]+\/)(?:[\w.@+-]+\/)*(?:[\w@+-][\w.@+-]*\.[A-Za-z0-9]{1,12}(?::\d+(?::\d+|-\d+)?|#L\d+(?:C\d+|-L\d+)?)?(?![\w/#-]|:\w|\.\d)|(?![\w@+-]|\.\w))|[\w@+-][\w.@+-]*\.[A-Za-z0-9]{1,12}(?::\d+(?::\d+|-\d+)?|#L\d+(?:C\d+|-L\d+)?)?(?![\w/#-]|:\w|\.\d)))/g;

export function textLinks(text: string): TextLink[] {
  if (!/[/.]/.test(text)) return [];
  const out: TextLink[] = [];
  for (const match of text.matchAll(TEXT_LINK)) {
    let value = match[0];
    if (match[1] || match[2]) value = value.replace(/[.,;:!?*_]+$/, "");
    const start = match.index!;
    const end = start + value.length;
    if (match[2]) {
      if (/^https?:\/\/[^/?#]*[A-Za-z0-9]/.test(value)) out.push({ kind: "url", start, end, value });
      continue;
    }
    const target = match[1] ? linkReplyPath(value) : pathLocation(value);
    if (target && isFileLocation(target) && (target.path.includes("/") || target.location))
      out.push({ kind: "path", start, end, value, ...target });
  }
  return out;
}

// A bare host:port is not a file location. Folder-qualified names remain unambiguous files.
function isFileLocation(target: ReplyPath): boolean {
  return (
    isPathShape(target.path) &&
    !(
      target.suffix?.startsWith(":") &&
      !target.path.includes("/") &&
      /\.(?:com|org|net|edu|gov|mil|int|io|dev|app|co|uk|au|nz|info|biz|me|tv|xyz|online|site|tech|ai|local)$/i.test(
        target.path,
      )
    )
  );
}

/// A raster image the pane draws as a thumbnail: PNG, JPEG, GIF or WebP, by file extension.
const IMAGE_FILE = /\.(?:png|jpe?g|gif|webp)$/i;

export function isImagePath(path: string): boolean {
  return IMAGE_FILE.test(path);
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

function safeDecode(text: string): string {
  try {
    return decodeURIComponent(text);
  } catch {
    return text;
  }
}

/// Folders under a home folder that hold credentials, and secret file names (D4).
const DENIED_FOLDER = /(?:^|\/)(?:\.ssh|\.gnupg|Library\/Keychains|\.aws|\.config\/gh)(?:\/|$)/;

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
