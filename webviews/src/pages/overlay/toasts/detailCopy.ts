// A toast's detail as its Details shows it (moved from CmuxToastDetailCopy.swift): a known error code
// in a raw reason ("cannot copy the build to the machine: fs.no_space: no space left on the device")
// becomes plain words ("The machine is out of disk space."), and the code stays under it as secondary
// text to copy into a bug. A detail with no known code, or of several lines (one per machine), stays
// as it came. Pure.
//
// Leo, 2026-11-01, on the expanded "Couldn't update" toast that showed the raw reason with
// `fs.no_space` in it: "ok tho the details toast doesnt look very good".

/** What the toast shows as the detail: plain words (with the code they stand for), or the raw detail. */
export interface DetailCopy {
  text: string;
  code?: string;
}

/** The string key of each code's plain words. The codes are the daemon's `fs.*` refusals (cmux-tui
 * `fs_ops/error.rs`) and the sync CLI's `disk_full`. */
const WORDS: Readonly<Record<string, string>> = {
  "fs.no_space": "overlay.toasts.detail.noSpace",
  disk_full: "overlay.toasts.detail.noSpace",
  "fs.read_only": "overlay.toasts.detail.readOnly",
  "fs.permission_denied": "overlay.toasts.detail.permissionDenied",
  "fs.too_large": "overlay.toasts.detail.tooLarge",
};

/** The string key of `code`'s plain words; undefined for any other code. */
export function wordsKey(code: string): string | undefined {
  return Object.hasOwn(WORDS, code) ? WORDS[code] : undefined;
}

/** The code-shaped words of `detail` in order: runs of lowercase letters, digits, `_` and `.`, with
 * no leading or trailing dot ("fs.no_space" out of "...: fs.no_space: ..."). */
export function codes(detail: string): string[] {
  return detail
    .split(/[^a-z0-9_.]+/)
    .map((word) => word.replace(/^\.+|\.+$/g, ""))
    .filter((word) => word.length > 0);
}

/** The plain words of `detail`'s first known code, with the code; the raw detail when it names none,
 * or has several lines (each its own reason, which one sentence would hide). `t` reads a string key. */
export function plainDetail(detail: string, t: (key: string) => string): DetailCopy {
  if (/[\n\r\v\f\u0085\u2028\u2029]/.test(detail)) return { text: detail };
  const code = codes(detail).find((word) => wordsKey(word) !== undefined);
  const key = code && wordsKey(code);
  return code && key ? { text: t(key), code } : { text: detail };
}
