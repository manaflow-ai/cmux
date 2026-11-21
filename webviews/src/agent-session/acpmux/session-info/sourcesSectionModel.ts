import { type Translate } from "../i18n";
import { numberedImageLabels } from "../imageLabel";
import { NativeError } from "../nativeError";
import type { SummarySource } from "../summary/sessionSummary";

export const SOURCES_SHOWN = 4;
// Native tab refusal preserves the gesture, so the validated editor route can retry.
export async function openSourceFile(
  path: string,
  native: (method: string, params: Record<string, unknown>) => Promise<unknown>,
) {
  try {
    return await native("file.open", { path, where: "tab" });
  } catch (error) {
    if (!(error instanceof NativeError) || error.code !== "transport.path_invalid") throw error;
    return native("file.open", { path, where: "editor" });
  }
}

/// Each source's row name, in order: a pasted image with no name of its own (WebKit's "image.png")
/// is "Screenshot 1", "Screenshot 2", ... in chat order, numbered across the whole list so a row
/// keeps its number when View all unfolds; every other source is its label.
export function sourceLabels(t: Translate, sources: readonly SummarySource[]): string[] {
  const images = sources.filter((source) => source.kind === "image");
  const named = numberedImageLabels(
    t,
    images.map((source) => ({ name: source.label, source: source.image?.source })),
  );
  const labels = new Map(images.map((source, index) => [source, named[index]!]));
  return sources.map((source) => labels.get(source) ?? source.label);
}

export function scopedPath(path: string, cwd?: string): string | undefined {
  if (!cwd?.startsWith("/") || path.startsWith("~") || path.includes("\0")) return;
  const normalize = (value: string) => {
    const parts: string[] = [];
    for (const part of value.split("/"))
      if (part === "..") parts.pop();
      else if (part && part !== ".") parts.push(part);
    return `/${parts.join("/")}`;
  };
  const root = normalize(cwd),
    resolved = normalize(path.startsWith("/") ? path : `${root}/${path}`);
  return resolved.startsWith(root === "/" ? root : `${root}/`) ? resolved : undefined;
}
