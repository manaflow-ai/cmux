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
  const parts = [payload.sourceLabel, payload.repoRoot, payload.branchBaseRef]
    .filter((value) => typeof value === "string" && value.trim() !== "");
  return parts.join(" | ");
}

// The stage/commit command is intentionally REPO-scoped, not diff-scoped: it
// runs `git add --all` against `repoRoot` and therefore commits the user's
// entire current working tree, independent of which diff source (unstaged,
// staged, branch, last-turn) is on screen. Applying exactly the displayed patch
// is the sibling `copyGitApplyCommand` (`git apply`) action; this one is the
// deliberate "stage everything and commit" shortcut described in the PR. The
// result is only ever copied to the clipboard for the user to read and run
// manually — the app never executes it — so a visible `git add --all` is the
// documented contract, not a hidden side effect.
export function buildStageCommitCommand(repoRoot: string | undefined, message: string): string {
  if (repoRoot == null || repoRoot.trim() === "") {
    throw new Error("Missing repository path");
  }

  const normalizedMessage = message.replace(/\r\n?/g, "\n").trim();
  if (normalizedMessage === "") {
    throw new Error("Missing commit message");
  }

  const newline = String.fromCharCode(10);
  const commitMessage = `${normalizedMessage}${newline}`;
  const delimiter = safeHereDocDelimiter(commitMessage, "CMUX_COMMIT_MESSAGE");
  const quotedRepoRoot = shellSingleQuote(repoRoot);
  return [
    `git -C ${quotedRepoRoot} add --all && git -C ${quotedRepoRoot} commit -F - <<'${delimiter}'`,
    commitMessage + delimiter,
  ].join(newline);
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
  const newline = String.fromCharCode(10);
  const patch = patchText.endsWith(newline) ? patchText : `${patchText}${newline}`;
  const delimiter = safeHereDocDelimiter(patch, "CMUX_DIFF_PATCH");
  const command = `git apply <<'${delimiter}'${newline}${patch}${delimiter}`;
  await copyText(command, fallbackTextarea);
  return label("copiedGitApplyCommand");
}

export async function copyStageCommitCommand(
  repoRoot: string | undefined,
  message: string,
  label: DiffViewerLabelResolver,
  fallbackTextarea: HTMLTextAreaElement | null,
): Promise<string> {
  const command = buildStageCommitCommand(repoRoot, message);
  await copyText(command, fallbackTextarea);
  return label("copiedStageCommitCommand");
}

async function copyText(text: string, fallbackTextarea: HTMLTextAreaElement | null): Promise<void> {
  if (navigator.clipboard?.writeText) {
    try {
      await navigator.clipboard.writeText(text);
      return;
    } catch {
      // WebKit can expose Clipboard API but reject after the async patch fetch loses user activation.
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

function shellSingleQuote(value: string): string {
  return `'${value.replace(/'/g, `'"'"'`)}'`;
}

function safeHereDocDelimiter(text: string, base: string): string {
  const lines = new Set(text.split(/\r?\n/));
  let delimiter = base;
  let index = 0;
  while (lines.has(delimiter)) {
    index += 1;
    delimiter = `${base}_${index}`;
  }
  return delimiter;
}
