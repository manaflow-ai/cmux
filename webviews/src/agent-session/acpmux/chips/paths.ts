// Which reply text names a local path, for its chip (decision D4). The page only decides how a
// path looks; the host checks every open again (file.open: the pane's roots and a user gesture).
// A path on the deny list draws as plain text here, and the host refuses it as well.

/// A local path a link points at: absolute (`/Users/…/README.md`) or a `file://` URL. Relative
/// links stay as they are until the host resolves them against the session's folder.
export function linkPath(href: string): string | undefined {
  if (href.startsWith("/") && !href.startsWith("//")) return stripLine(safeDecode(href.split(/[?#]/)[0]!));
  if (/^file:\/\//i.test(href)) {
    try {
      const url = new URL(href);
      if (url.host && url.host !== "localhost") return undefined;
      return stripLine(decodeURIComponent(url.pathname));
    } catch {
      return undefined;
    }
  }
  return undefined;
}

/// An inline code span that is a path: absolute, with a folder in it, and either a file name
/// with an extension or a trailing slash (`/tmp/app.log`, `/Users/me/repo/src/`), optionally
/// with a `:line[:col]` suffix. Shell commands, globs and flags stay code.
export function codePath(text: string): string | undefined {
  const value = text.trim();
  if (!/^\/[^\s`'"<>|*?$;&(){}[\]]+$/.test(value)) return undefined;
  const path = stripLine(value);
  const parts = path.split("/").filter(Boolean);
  if (parts.length < 2) return undefined;
  if (!path.endsWith("/") && !/\.[A-Za-z0-9]{1,12}$/.test(parts.at(-1)!)) return undefined;
  return path;
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
