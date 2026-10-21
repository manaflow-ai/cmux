// An opened edit inside the transcript: a card per changed file with its name, the lines added
// and removed, Wrap lines and copy, and the change on @pierre/diffs: its first lines under a fade
// with Show all N lines when it is long (BlockParts.tsx). A prose file (Markdown, text) wraps with a
// hanging indent; code keeps its lines whole, its right edge fading while more lies past it. The
// changes view (changes/EditBlock.tsx) draws the same edits at full size.
import { lazy, Suspense, useMemo, useState } from "react";
import { editPatch, type TurnFile } from "../diff";
import { copyText } from "./clipboard";
import { Copy } from "./icons";
import { useT } from "../i18n";
import { fileBlockKind, useBlockWrap } from "./blockWrap";
import { PreviewMore, usePreview, useSidewaysRef, WrapButton } from "./BlockParts";

/// The card's lines (EditDiffHunks.tsx, on @pierre/diffs) come in their own chunk, so the page's
/// first script parses without Pierre (bd cx-z9kz0). The header shows at once; the page starts the
/// chunk once it has painted (App.tsx), so the lines rarely wait.
export const loadEditDiffHunks = () => import("./EditDiffHunks");
const EditDiffHunks = lazy(() => loadEditDiffHunks().then((module) => ({ default: module.EditDiffHunks })));

export function EditDiff({ file }: { file: TurnFile }) {
  const t = useT();
  const [copied, setCopied] = useState(false);
  const patches = useMemo(() => file.edits.map((edit) => editPatch(file, edit)), [file]);
  const name = file.path.split("/").pop() || file.path;
  const kind = fileBlockKind(file.path);
  const [wrap] = useBlockWrap(kind);
  const preview = usePreview(
    file.edits.reduce((sum, edit) => sum + edit.hunks.reduce((lines, hunk) => lines + hunk.lines.length, 0), 0),
  );
  const body = useSidewaysRef<HTMLDivElement>();
  return (
    <div className="cv-edit-diff" data-wrap={wrap}>
      <div className="cv-edit-diff__header">
        <span className="cv-edit-diff__name" data-path={file.path}>
          {name}
        </span>
        <span className="cv-edit-diff__add">+{file.additions}</span>
        <span className="cv-edit-diff__del">-{file.deletions}</span>
        <WrapButton kind={kind} className="cv-codeblock__action cv-edit-diff__wrap" />
        <button
          type="button"
          className="cv-codeblock__action cv-edit-diff__copy"
          aria-label={copied ? t("code.copied") : t("code.copyDiff")}
          onClick={() =>
            void copyText(patches.join("")).then(
              () => setCopied(true),
              () => setCopied(false),
            )
          }
        >
          <Copy />
        </button>
      </div>
      <div ref={body} className="cv-edit-diff__body" data-preview={preview.attribute}>
        <Suspense fallback={null}>
          <EditDiffHunks file={file} patches={patches} wrap={wrap} />
        </Suspense>
      </div>
      <PreviewMore preview={preview} />
    </div>
  );
}
