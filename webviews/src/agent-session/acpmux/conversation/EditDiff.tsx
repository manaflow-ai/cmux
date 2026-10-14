// An opened edit inside the transcript: a card per changed file with its
// name, the lines added and removed, copy, and the change on @pierre/diffs, scrolling past a
// few lines. The changes view (changes/EditBlock.tsx) draws the same edits at full size.
import { lazy, Suspense, useMemo, useState } from "react";
import { editPatch, type TurnFile } from "../diff";
import { copyText } from "./clipboard";
import { Copy } from "./icons";
import { useT } from "../i18n";

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
  return (
    <div className="cv-edit-diff">
      <div className="cv-edit-diff__header">
        <span className="cv-edit-diff__name" data-path={file.path}>
          {name}
        </span>
        <span className="cv-edit-diff__add">+{file.additions}</span>
        <span className="cv-edit-diff__del">-{file.deletions}</span>
        <button
          type="button"
          className="cv-codeblock__action cv-edit-diff__copy"
          aria-label={copied ? t("code.copied") : t("code.copyDiff")}
          title={copied ? t("code.copied") : t("code.copyDiff")}
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
      <div className="cv-edit-diff__body">
        <Suspense fallback={null}>
          <EditDiffHunks file={file} patches={patches} />
        </Suspense>
      </div>
    </div>
  );
}
