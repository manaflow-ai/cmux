// An opened edit inside the transcript: a card per changed file with its name, the lines added
// and removed, Wrap lines and copy, and the change on @pierre/diffs: its first lines under a fade
// with Show all N lines when it is long (BlockParts.tsx). A prose file (Markdown, text) wraps with a
// hanging indent; code keeps its lines whole, its right edge fading while more lies past it. The
// changes view (changes/EditBlock.tsx) draws the same edits at full size.
import { lazy, Suspense, useContext, useLayoutEffect, useMemo, useRef, useState, type ComponentType } from "react";
import { editPatch, type TurnFile } from "../diff";
import { copyTextResult } from "./clipboard";
import { Copy } from "./icons";
import { useT } from "../i18n";
import { fileBlockKind, useBlockWrap } from "./blockWrap";
import { PreviewMore, usePreview, useSidewaysRef, WrapButton } from "./BlockParts";
import { FindReveal, foldFind } from "./chatFind";
import { EditDiffLoading, useDiffPainted } from "./EditDiffLoading";

/// The card's lines (EditDiffHunks.tsx, on @pierre/diffs) come in their own chunk, so the page's
/// first script parses without Pierre (bd cx-z9kz0). The header shows at once; the page starts the
/// chunk once it has painted (App.tsx), so the lines rarely wait.
export const loadEditDiffHunks = () => import("./EditDiffHunks");
const EditDiffHunks = lazy(() => loadEditDiffHunks().then((module) => ({ default: module.EditDiffHunks })));

/// Bumps each time Find in Chat's current match is in `file` (its text, or the call that made it),
/// so a cut diff opens wherever it is drawn: a call's row, an edits group, the edited-files card.
function useFindInFile(file: TurnFile) {
  const reveal = useContext(FindReveal);
  const text = useMemo(
    () =>
      foldFind(
        file.edits.flatMap((edit) => edit.hunks.flatMap((hunk) => hunk.lines.map((line) => line.text))).join("\n"),
      ),
    [file],
  );
  const hit = Boolean(
    reveal &&
    (reveal.toolId !== undefined
      ? file.edits.some((edit) => edit.toolId === reveal.toolId)
      : reveal.needle && text.includes(reveal.needle)),
  );
  const [found, setFound] = useState(0);
  useLayoutEffect(() => {
    if (!hit) return;
    setFound((count) => count + 1);
    reveal?.repaint();
    // eslint-disable-next-line react-hooks/exhaustive-deps -- a new match opens, not a new callback
  }, [hit, reveal]);
  return found;
}

type EditDiffProps = {
  file: TurnFile;
  /** Bumped when Find in Chat reveals the call: opens the preview, as the match may be past it. */
  reveal?: number;
  /** Never cut to a preview (an edit a permission ask is about). */
  whole?: boolean;
};

export function EditDiff(props: EditDiffProps) {
  return <EditDiffFrame {...props} hunks={EditDiffHunks} />;
}

/** The real card and preview boundary, also used by the gallery with a deferred renderer. */
export function EditDiffFrame({
  file,
  reveal = 0,
  whole = false,
  hunks: Hunks,
}: EditDiffProps & {
  hunks: ComponentType<{ file: TurnFile; patches: string[]; wrap: boolean }>;
}) {
  const t = useT();
  const [copied, setCopied] = useState(false);
  const patches = useMemo(() => file.edits.map((edit) => editPatch(file, edit)), [file]);
  const name = file.path.split("/").pop() || file.path;
  const kind = fileBlockKind(file.path);
  const [wrap] = useBlockWrap(kind);
  const found = useFindInFile(file);
  const preview = usePreview(
    whole
      ? 0
      : file.edits.reduce((sum, edit) => sum + edit.hunks.reduce((lines, hunk) => lines + hunk.lines.length, 0), 0),
    reveal + found,
  );
  const body = useSidewaysRef<HTMLDivElement>();
  const hunks = useRef<HTMLDivElement>(null);
  const painted = useDiffPainted(hunks);
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
            void copyTextResult(patches.join("")).then(
              (accepted) => setCopied(accepted),
              () => setCopied(false),
            )
          }
        >
          <Copy />
        </button>
      </div>
      <div ref={body} className="cv-edit-diff__body" data-preview={preview.attribute}>
        {/* The placeholder holds the body's height until Pierre has drawn every edit: the renderer's
            chunk resolves first, then each host fills a frame or more later, so a Suspense fallback
            alone left an empty body for a frame. Both share one grid cell, the lines hidden. */}
        <div className="cv-edit-diff__stack" data-painted={painted || undefined}>
          <div ref={hunks} className="cv-edit-diff__hunks">
            <Suspense fallback={null}>
              <Hunks file={file} patches={patches} wrap={wrap} />
            </Suspense>
          </div>
          {painted ? null : <EditDiffLoading file={file} wrap={wrap} />}
        </div>
      </div>
      <PreviewMore preview={preview} />
    </div>
  );
}
