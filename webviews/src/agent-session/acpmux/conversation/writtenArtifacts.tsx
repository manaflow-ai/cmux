// Use recorded full contents, never read a path from disk or mistake an edit hunk for a document.
import { useContext, useMemo } from "react";
import type { AcpmuxActivity } from "../model";
import { useT } from "../i18n";
import { hasNativeHost, postNative } from "../native";
import { ArtifactContext, type Artifact } from "./artifactPreview";
import { toolArtifacts } from "./artifactWrites";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

/// Whether a written file also opens as the real page beside the chat: an HTML file with an absolute
/// path, which the host renders in a sandboxed browser tab with its relative assets (u18051).
export const opensBeside = (artifact: Artifact) => artifact.kind === "html" && Boolean(artifact.path?.startsWith("/"));

/// Opens the written page beside the chat on the person's click (`file.open` in a tab: the host checks the
/// roots and spends the click). A host that refuses (a remote chat's path, a file since deleted) leaves the
/// in-chat panel as the way to see it.
export async function openBeside(artifact: Artifact, fallback: (artifact: Artifact) => void) {
  try {
    await postNative("file.open", { path: artifact.path, where: "tab" });
  } catch {
    fallback(artifact);
  }
}

/** The same Open action for a lone write, a folded edits group and Session Info's Outputs. */
export function WrittenArtifactButtons({ tools }: { tools: readonly Tool[] }) {
  const open = useContext(ArtifactContext);
  const t = useT();
  const artifacts = useMemo(() => tools.flatMap(toolArtifacts), [tools]);
  if (!open || !artifacts.length) return null;
  const beside = hasNativeHost();
  return (
    <div>
      {artifacts.map((artifact, index) => (
        <span key={`${artifact.path}:${index}`}>
          <button
            type="button"
            className="acpmux-review-changes"
            aria-label={t("artifact.open")}
            title={artifact.path}
            onClick={() => open(artifact)}
          >
            {t("artifact.open")} · {artifact.path?.split("/").pop()}
          </button>
          {beside && opensBeside(artifact) && (
            <button
              type="button"
              className="acpmux-review-changes"
              aria-label={t("artifact.openBeside")}
              title={artifact.path}
              onClick={() => void openBeside(artifact, open)}
            >
              {t("artifact.openBeside")}
            </button>
          )}
        </span>
      ))}
    </div>
  );
}
