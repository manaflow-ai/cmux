import type { DiffViewerLabelResolver } from "./labels";

export function resolveDiffNavigationURL(rawURL: string): string {
  // Root-relative URLs (the branch picker rebases its endpoints against the
  // current page origin) resolve natively against `window.location` for BOTH
  // the HTTP server and the custom-scheme page, so pass them through unchanged.
  // They must never enter the http->scheme segment-drop rewrite below: that
  // rewrite assumes an absolute http(s) URL whose first path segment is a token
  // and would otherwise mangle a relative path's query/host.
  if (!hasURLScheme(rawURL)) {
    return rawURL;
  }
  try {
    const target = new URL(rawURL, window.location.href);
    if (
      window.location.protocol === "cmux-diff-viewer:" &&
      (target.protocol === "http:" || target.protocol === "https:")
    ) {
      const rest = target.pathname.split("/").filter(Boolean).slice(1).join("/");
      return `cmux-diff-viewer://${window.location.host}/${rest}`;
    }
    return target.href;
  } catch {
    return rawURL;
  }
}

// Whether `url` begins with an explicit `scheme://` or `scheme:` prefix (e.g.
// `http://`, `cmux-diff-viewer://`, `data:`). A root-relative path (`/foo?x`)
// or a protocol-relative/relative path has no scheme and is left for the
// browser to resolve against the current document.
function hasURLScheme(url: string): boolean {
  return /^[a-zA-Z][\w+.-]*:/.test(url);
}

export function diffSourceDetail(payload: any): string {
  const parts = [payload.sourceLabel, payload.repoRoot, payload.branchBaseRef].filter(
    (value) => typeof value === "string" && value.trim() !== "",
  );
  return parts.join(" | ");
}

export async function copyGitApplyCommand(
  patchURL: string | undefined,
  label: DiffViewerLabelResolver,
  fallbackTextarea: HTMLTextAreaElement | null,
): Promise<string> {
  if (!patchURL) {
    throw new Error("Missing patch URL");
  }
  const response = await fetch(patchURL, { cache: "no-store" });
  if (!response.ok) {
    throw new Error(`${label("loadingDiff")} (${response.status})`);
  }
  const patchText = await response.text();
  // Validate and build before touching either clipboard path so an unsafe
  // patch never reaches the system clipboard in any form.
  const command = buildGitApplyCommand(patchText);
  if (navigator.clipboard?.writeText) {
    try {
      await navigator.clipboard.writeText(command);
      return label("copiedGitApplyCommand");
    } catch {
      // WebKit can expose Clipboard API but reject after the async patch fetch loses user activation.
    }
  }
  if (!fallbackTextarea) {
    throw new Error("Clipboard API unavailable");
  }
  fallbackTextarea.value = command;
  fallbackTextarea.select();
  if (!document.execCommand("copy")) {
    throw new Error("Clipboard copy failed");
  }
  return label("copiedGitApplyCommand");
}

/** Copies `text` to the clipboard, through the hidden textarea where the Clipboard API refuses. */
export async function copyText(text: string, fallbackTextarea: HTMLTextAreaElement | null): Promise<void> {
  if (navigator.clipboard?.writeText) {
    try {
      await navigator.clipboard.writeText(text);
      return;
    } catch {
      // Fall through to the textarea, as for the git apply command.
    }
  }
  if (!fallbackTextarea) {
    throw new Error("Clipboard API unavailable");
  }
  fallbackTextarea.value = text;
  fallbackTextarea.select();
  if (!document.execCommand("copy")) {
    throw new Error("Clipboard copy failed");
  }
}

// C0 controls other than tab, LF, and CR, plus DEL and the C1 range. Pasted
// into an interactive shell these can act as line editor commands or terminal
// escape sequences (for example ending bracketed paste), so a patch carrying
// any of them is never turned into a shell command.
// oxlint-disable-next-line no-control-regex -- matching control characters is the point.
const UNSAFE_SHELL_PASTE_CONTROL = /[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F-\u009F]/;

// Every sequence an interactive shell or terminal treats as a line boundary.
// A bare CR submits a line just like LF, so it must split lines here too.
const SHELL_LINE_BOUNDARY = /\r\n|\r|\n/;

const GIT_APPLY_DELIMITER_PREFIX = "CMUX_DIFF_PATCH_";

/**
 * Builds a `git apply` command that feeds `patchText` through a quoted heredoc.
 *
 * Throws when the patch contains control characters that are unsafe to paste
 * into a shell. The heredoc delimiter is random and is guaranteed not to occur
 * anywhere in the patch, so no patch line (split on CRLF, CR, or LF) can end the
 * heredoc early.
 */
export function buildGitApplyCommand(patchText: string, randomToken: () => string = randomDelimiterToken): string {
  if (UNSAFE_SHELL_PASTE_CONTROL.test(patchText)) {
    throw new Error("Patch contains control characters");
  }
  const newline = "\n";
  const patch = patchText.endsWith(newline) ? patchText : `${patchText}${newline}`;
  const delimiter = gitApplyDelimiter(patch, randomToken);
  return `git apply <<'${delimiter}'${newline}${patch}${delimiter}`;
}

function gitApplyDelimiter(patch: string, randomToken: () => string): string {
  const lines = new Set(patch.split(SHELL_LINE_BOUNDARY));
  for (let attempt = 0; attempt < 16; attempt += 1) {
    const token = randomToken();
    if (!/^[A-Za-z0-9]+$/.test(token)) {
      continue;
    }
    const delimiter = `${GIT_APPLY_DELIMITER_PREFIX}${token}`;
    if (!patch.includes(delimiter) && !lines.has(delimiter)) {
      return delimiter;
    }
  }
  throw new Error("Could not choose a unique heredoc delimiter");
}

function randomDelimiterToken(): string {
  const bytes = new Uint8Array(12);
  globalThis.crypto.getRandomValues(bytes);
  return Array.from(bytes, (byte) => byte.toString(16).padStart(2, "0")).join("");
}
