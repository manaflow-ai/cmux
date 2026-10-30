// Use recorded full contents, never read a path from disk or mistake an edit hunk for a document.
import { useContext, useMemo } from "react";
import type { AcpmuxActivity, AcpmuxRow } from "../model";
import { pathKey, toolCanonical } from "../model";
import { useT } from "../i18n";
import { ArtifactContext, type Artifact } from "./artifactPreview";

type Tool = NonNullable<AcpmuxActivity["tool"]>;
const cache = new WeakMap<Tool, Artifact[]>();
export function toolArtifacts(tool: Tool): Artifact[] {
  if (tool.status !== "completed" || !["edit", "fileChange"].includes(tool.kind ?? "")) return [];
  const previous = cache.get(tool);
  if (previous) return previous;
  const full = (tool.diffs ?? []).filter((diff) => !diff.fragment || (diff.fromInput && diff.oldText == null));
  // Claude/pi/Gemini may send the whole write in rawInput without a diff block.
  if (!full.length && /^(write|write_file|writefile|create_file)(?:\s|$)/i.test(tool.title)) {
    try {
      const input = JSON.parse(tool.inputSummary ?? "null");
      const path = input?.file_path ?? input?.path;
      if (typeof path === "string" && typeof input?.content === "string")
        full.push({ path, canonical: toolCanonical(tool, path), newText: input.content });
    } catch {
      /* A truncated or non-JSON input is not a document. */
    }
  }
  const result = full
    .filter((diff) => /\.html?$/i.test(diff.path) && diff.newText.length > 0)
    .map((diff): Artifact => ({ kind: "html", lang: "html", code: diff.newText, path: pathKey(diff) }));
  cache.set(tool, result);
  return result;
}
export function writtenArtifacts(rows: readonly AcpmuxRow[]): Artifact[] {
  return rows.flatMap((row) => (row.items ?? []).flatMap((item) => (item.tool ? toolArtifacts(item.tool) : [])));
}
/** The same Open action for a lone write, a folded edits group and the Inspector's Outputs. */
export function WrittenArtifactButtons({ tools }: { tools: readonly Tool[] }) {
  const open = useContext(ArtifactContext);
  const t = useT();
  const artifacts = useMemo(() => tools.flatMap(toolArtifacts), [tools]);
  if (!open || !artifacts.length) return null;
  return (
    <div>
      {artifacts.map((artifact, index) => (
        <button
          key={`${artifact.path}:${index}`}
          type="button"
          className="acpmux-review-changes"
          aria-label={t("artifact.open")}
          title={artifact.path}
          onClick={() => open(artifact)}
        >
          {t("artifact.open")} · {artifact.path?.split("/").pop()}
        </button>
      ))}
    </div>
  );
}
