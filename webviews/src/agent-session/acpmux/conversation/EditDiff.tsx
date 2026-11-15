// An opened edit inside the transcript: a card per changed file with its name, the lines added
// and removed, Wrap lines and copy, and the change on @pierre/diffs, whole up to `OUTPUT_BOX_LINES`
// lines and scrolling inside a box that tall past them (outputScrollBox.css). A prose file (Markdown, text) wraps with a
// hanging indent; code keeps its lines whole, its right edge fading while more lies past it. The
// changes view (changes/EditBlock.tsx) draws the same edits at full size.
import { cornerAction } from "./cornerActions";
import {
  lazy,
  Suspense,
  useCallback,
  useContext,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type ComponentType,
} from "react";
import { editPatch, type TurnFile } from "../diff";
import { copyTextResult } from "./clipboard";
import { Copy } from "./icons";
import { useT } from "../i18n";
import { fileBlockKind, useBlockWrap } from "./blockWrap";
import { WrapButton } from "./BlockParts";
import { OUTPUT_SCROLL_BOX, useSidewaysEdge } from "./blockPartsModel";
import { FindReveal, foldFind } from "./chatFind";
import { watchOutputViewport } from "./outputViewport";
import "./outputScrollBox.css";
import { EditDiffLoading } from "./EditDiffLoading";
import { useDiffPainted } from "./editDiffLoadingModel";
import { loadEditDiffHunks } from "./editDiffModel";
const EditDiffHunks = lazy(() => loadEditDiffHunks().then((module) => ({ default: module.EditDiffHunks })));

/// Asks for a repaint each time Find in Chat's current match is in `file` (its text, or the call
/// that made it), so the match's mark lands in the diff's lines once Pierre has drawn them, wherever
/// it is drawn: a call's row, an edits group, the edited-files card.
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
  useLayoutEffect(() => {
    if (!hit) return;
    reveal?.repaint();
    // eslint-disable-next-line react-hooks/exhaustive-deps -- a new match repaints, not a new callback
  }, [hit, reveal]);
}

type EditDiffProps = {
  file: TurnFile;
  /** Bumped when Find in Chat reveals the call. Every line is drawn already: nothing to open. */
  reveal?: number;
  /** Never held in a scroll box: every line drawn in the card (an edit a permission ask is about). */
  whole?: boolean;
};

export function EditDiff(props: EditDiffProps) {
  return <EditDiffFrame {...props} hunks={EditDiffHunks} />;
}

/** The real card and preview boundary, also used by the gallery with a deferred renderer. */
export function EditDiffFrame({
  file,
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
  useFindInFile(file);
  const body = useRef<HTMLDivElement>(null);
  useSidewaysEdge(body);
  const edges = useCallback(
    (node: HTMLDivElement | null) => {
      body.current = node;
      return node && !whole ? watchOutputViewport(node) : undefined;
    },
    [body, whole],
  );
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
        <WrapButton kind={kind} className={`${cornerAction()} cv-edit-diff__wrap`} />
        <button
          type="button"
          className={`${cornerAction()} cv-edit-diff__copy`}
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
      <div
        ref={edges}
        className={whole ? "cv-edit-diff__body" : `cv-edit-diff__body ${OUTPUT_SCROLL_BOX}`}
        // oxlint-disable-next-line jsx-a11y/no-noninteractive-tabindex -- focus the scroll box to read it with arrow keys.
        tabIndex={whole ? undefined : 0}
      >
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
    </div>
  );
}
