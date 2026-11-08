// Use recorded full contents, never read a path from disk or mistake an edit hunk for a document.
import { useContext, useMemo } from "react";
import type { AcpmuxActivity } from "../model";
import { useT } from "../i18n";
import { ArtifactContext } from "./artifactPreview";
import { toolArtifacts } from "./artifactWrites";

type Tool = NonNullable<AcpmuxActivity["tool"]>;
/** The same Open action for a lone write, a folded edits group and Session Info's Outputs. */
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
