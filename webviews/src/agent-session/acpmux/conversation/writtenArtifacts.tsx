// Use recorded full contents, never read a path from disk or mistake an edit hunk for a document.
import { useContext, useMemo } from "react";
import type { AcpmuxActivity } from "../model";
import { useT } from "../i18n";
import { callChipHost } from "../chips/host";
import { hasNativeHost, postNative } from "../native";
import { useExperimentSwitch } from "../../../experiments/switches";
import { ArtifactContext, type Artifact } from "./artifactPreview";
import { toolArtifacts } from "./artifactWrites";
import { isMarkdownPath } from "./writtenArtifactsModel";

type Tool = NonNullable<AcpmuxActivity["tool"]>;

/// Whether a written file also opens as the real page beside the chat: an HTML file with an absolute
/// path, which the host renders in a sandboxed browser tab with its relative assets (u18051).
export const opensBeside = (artifact: Artifact) => artifact.kind === "html" && Boolean(artifact.path?.startsWith("/"));

/// Opens the written page beside the chat on the person's click (`file.open` in a tab: the host checks the
/// switch and the roots, and spends the click). A host that refuses (the switch is off there, a remote
/// chat's path, a file since deleted) leaves the in-chat panel as the way to see it.
export async function openBeside(artifact: Artifact, fallback: (artifact: Artifact) => void) {
  try {
    await postNative("file.open", { path: artifact.path, where: "tab" });
  } catch {
    fallback(artifact);
  }
}

/** The same Open action for a lone write, a folded edits group and Session Info's Outputs. With
 * `experiments.writtenHTMLOpenBeside` on (off by default), a written HTML file also gets Open beside chat
 * (docs/design/next-rich-output.md, plan item 5). */
export function WrittenArtifactButtons({ tools }: { tools: readonly Tool[] }) {
  const open = useContext(ArtifactContext);
  const t = useT();
  const besideOn = useExperimentSwitch("writtenHTMLOpenBeside");
  const artifacts = useMemo(() => tools.flatMap(toolArtifacts), [tools]);
  if (!open || !artifacts.length) return null;
  const beside = besideOn && hasNativeHost();
  return (
    <div>
      {artifacts.map((artifact, index) => (
        <span key={`${artifact.path}:${index}`}>
          <button
            type="button"
            className="acpmux-review-changes"
            aria-label={t("artifact.open")}
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
