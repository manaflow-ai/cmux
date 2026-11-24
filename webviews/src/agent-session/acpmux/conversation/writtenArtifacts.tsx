// Use recorded full contents, never read a path from disk or mistake an edit hunk for a document.
import { useContext, useMemo } from "react";
import type { AcpmuxActivity } from "../model";
import { useT } from "../i18n";
import { callChipHost } from "../chips/host";
import { ArtifactContext } from "./artifactPreview";
import { toolArtifacts } from "./artifactWrites";
import { isMarkdownPath } from "./writtenArtifactsModel";

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
          onClick={() => open(artifact)}
        >
          {t("artifact.open")} · {artifact.path?.split("/").pop()}
        </button>
      ))}
    </div>
  );
}

/// Open on a Markdown file the agent wrote or changed, in the edited-files card's own place for that
/// file (one per file, however often the turn wrote it): the file in cmux's Markdown page beside the
/// chat, through the path chip's open (`link.openPath`: the deny list, the chat's folders, a user
/// gesture; a Cloud chat's file opens on its machine). The page reads the path, not the text a call
/// recorded, and follows the file as it changes, so a later write updates that same page
/// (docs/design/next-rich-output.md: no chip of its own in the chat). Nothing for any other file.
export function OpenWrittenMarkdown({ path }: { path: string }) {
  const t = useT();
  if (!isMarkdownPath(path)) return null;
  const name = path.split("/").pop() ?? path;
  return (
    <button
      type="button"
      className="acpmux-review-changes acpmux-edited-open"
      aria-label={`${t("artifact.open")} · ${name}`}
      title={path}
      onClick={() => void callChipHost("link.openPath", { path })}
    >
      {t("artifact.open")}
    </button>
  );
}
