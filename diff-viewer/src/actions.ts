import type { DiffViewerLabelResolver } from "./labels";

export function resolveDiffNavigationURL(rawURL: string): string {
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

export function diffSourceDetail(payload: any): string {
  const parts = [payload.sourceLabel, payload.repoRoot, payload.branchBaseRef]
    .filter((value) => typeof value === "string" && value.trim() !== "");
  return parts.join(" | ");
}

export async function copyGitApplyCommand(patchURL: string | undefined, label: DiffViewerLabelResolver): Promise<string> {
  if (!patchURL) {
    return label("renderFailed");
  }
  const response = await fetch(patchURL, { cache: "no-store" });
  if (!response.ok) {
    throw new Error(`${label("loadingDiff")} (${response.status})`);
  }
  const patchText = await response.text();
  const newline = String.fromCharCode(10);
  const patch = patchText.endsWith(newline) ? patchText : `${patchText}${newline}`;
  const delimiter = safeGitApplyDelimiter(patch);
  const command = `git apply <<'${delimiter}'${newline}${patch}${delimiter}`;
  if (!navigator.clipboard?.writeText) {
    throw new Error("Clipboard API unavailable");
  }
  await navigator.clipboard.writeText(command);
  return label("copiedGitApplyCommand");
}

function safeGitApplyDelimiter(patch: string): string {
  const lines = new Set(patch.split(/\r?\n/));
  let delimiter = "CMUX_DIFF_PATCH";
  let index = 0;
  while (lines.has(delimiter)) {
    index += 1;
    delimiter = `CMUX_DIFF_PATCH_${index}`;
  }
  return delimiter;
}
