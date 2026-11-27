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
  type ReactNode,
  type CSSProperties,
} from "react";
import { editPatch, type TurnFile } from "../diff";
import { copyTextResult } from "./clipboard";
import { Copy } from "./icons";
import { ChevronDown } from "../changeIcons";
import { HEADER_TOGGLE_ATTRIBUTE, HEADER_TOGGLES_ATTRIBUTE, headerToggleClick } from "./headerToggle";
import { useT } from "../i18n";
import { fileBlockKind, useBlockWrap } from "./blockWrap";
import { WrapButton } from "./BlockParts";
import { OUTPUT_SCROLL_BOX, useSidewaysEdge } from "./blockPartsModel";
import { FindReveal, foldFind } from "./chatFind";
import { watchOutputViewport } from "./outputViewport";
import "./outputScrollBox.css";
import { EditDiffLoading } from "./EditDiffLoading";
import { EDIT_DIFF_VARS } from "./editDiffBox";
import { useDiffPainted } from "./editDiffLoadingModel";
import { loadEditDiffHunks } from "./editDiffModel";
import { useFold } from "./fold";
import { Button } from "../../../ui/Button";
import { Tooltip } from "../../../ui/Tooltip";
import { foldPlays } from "./transcriptView";
const EditDiffHunks = lazy(() => loadEditDiffHunks().then((module) => ({ default: module.EditDiffHunks })));

/// Bumps each time Find in Chat's current match is in `file` (its text, or the call that made it), and
/// asks for a repaint, so a folded file opens and the match's mark lands in the diff's lines once
/// Pierre has drawn them, wherever it is drawn: a call's row, an edits group, the edited-files card.
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
    // eslint-disable-next-line react-hooks/exhaustive-deps -- a new match opens and repaints, not a new callback
  }, [hit, reveal]);
  return found;
}

type EditDiffProps = {
  file: TurnFile;
  /** Bumped when Find in Chat reveals the call. Every line is drawn already: nothing to open. */
  reveal?: number;
  /** Never held in a scroll box: every line drawn in the card (an edit a permission ask is about). */
  whole?: boolean;
  /** More corner actions after Wrap and copy (the edited-files card's Open in Changes). */
  actions?: ReactNode;
  /** The name its header shows, when not the file's own (the edited-files card's repo-relative path). */
  label?: string;
  /** Drawn inside a card of its own (the edited-files card): no ring, corner, fill or margin, so
   *  the header and diff sit directly on that card instead of in a second box (conversation.css). */
  flat?: boolean;
  /** Its name is a toggle that folds the file to its header (the edited-files card, where every file is
   *  drawn whole): a click on the name or the header's bare space, never on its buttons. */
  collapsible?: boolean;
};

export function EditDiff(props: EditDiffProps) {
  return <EditDiffFrame {...props} hunks={EditDiffHunks} />;
}

/** The real card and preview boundary, also used by the gallery with a deferred renderer. */
export function EditDiffFrame({
  file,
  whole = false,
  actions,
  label,
  flat = false,
  collapsible = false,
  hunks: Hunks,
}: EditDiffProps & {
  hunks: ComponentType<{ file: TurnFile; patches: string[]; wrap: boolean }>;
}) {
  const t = useT();
  const [copied, setCopied] = useState(false);
  const patches = useMemo(() => file.edits.map((edit) => editPatch(file, edit)), [file]);
  const name = label || file.path.split("/").pop() || file.path;
  const kind = fileBlockKind(file.path);
  const [wrap] = useBlockWrap(kind);
  const found = useFindInFile(file);
  const [collapsed, setCollapsed] = useState(false);
  // Find in Chat's match in a folded file opens it: before paint, as the transcript's other
  // disclosures open for Find.
  useLayoutEffect(() => {
    if (found) setCollapsed(false);
  }, [found]);
  const card = useRef<HTMLDivElement>(null);
  /// Folds or opens the file. Folded from its name while the name is stuck over the file's lines (the
  /// edited-files card's stack), the stack first scrolls back by how far the name had slid down, so the
  /// folded name stays where the reader clicked it instead of leaving the view with the lines.
  const toggleFold = () => {
    const node = card.current;
    const name = node?.firstElementChild;
    if (node && name && !collapsed) {
      const slid = name.getBoundingClientRect().top - node.getBoundingClientRect().top;
      const scroller = slid > 0.5 ? scrollerOf(node) : undefined;
      if (scroller) scroller.scrollTop -= slid;
    }
    setCollapsed((was) => !was);
  };
  const folded = collapsible && collapsed;
  // A file folds with the transcript's fold (fold.ts), as the card that holds it opens: its lines' height
  // and opacity on the shared token, the chevron turning with them (EditedFilesCard.css).
  const { present: drawn, ref: foldRef } = useFold(!folded, foldPlays);
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
  // The lines: in the box the fold sizes (`.cv-fold`) when the file folds, bare when it never does.
  const lines = (
    <>
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
    </>
  );
  const copyLabel = copied ? t("code.copied") : t("code.copyDiff");
  const nameLabel = (
    <span
      className="cv-edit-diff__name"
      data-path={file.path}
      // tooltip-allow: a long path is cut to the header; its whole path is the tooltip
      title={label}
    >
      {name}
    </span>
  );
  return (
    <div
      ref={card}
      className="cv-edit-diff"
      data-wrap={wrap}
      data-flat={flat || undefined}
      data-collapsed={folded || undefined}
      style={EDIT_DIFF_VARS as CSSProperties}
    >
      {/* The header's bare space shares its name's toggle (headerToggle.ts); its buttons keep their own clicks. */}
      {/* oxlint-disable-next-line jsx-a11y/click-events-have-key-events, jsx-a11y/no-static-element-interactions */}
      <div
        className="cv-edit-diff__header"
        {...(collapsible ? { [HEADER_TOGGLE_ATTRIBUTE]: "" } : {})}
        onClick={collapsible ? (event) => headerToggleClick(toggleFold)(event) : undefined}
      >
        {collapsible ? (
          <Button
            bare
            type="button"
            className="cv-edit-diff__toggle"
            aria-expanded={!collapsed}
            {...{ [HEADER_TOGGLES_ATTRIBUTE]: "" }}
          >
            <ChevronDown className="cv-edit-diff__chevron" width={12} height={12} />
            {nameLabel}
          </Button>
        ) : (
          nameLabel
        )}
        <span className="cv-edit-diff__add">+{file.additions}</span>
        <span className="cv-edit-diff__del">-{file.deletions}</span>
        <WrapButton kind={kind} className={`${cornerAction()} cv-edit-diff__wrap`} />
        <Tooltip label={copyLabel}>
          <button
            type="button"
            className={`${cornerAction()} cv-edit-diff__copy`}
            aria-label={copyLabel}
            onClick={() =>
              void copyTextResult(patches.join("")).then(
                (accepted) => setCopied(accepted),
                () => setCopied(false),
              )
            }
          >
            <Copy />
          </button>
        </Tooltip>
        {actions}
      </div>
      <div
        ref={edges}
        className={whole ? "cv-edit-diff__body" : `cv-edit-diff__body ${OUTPUT_SCROLL_BOX}`}
        // oxlint-disable-next-line jsx-a11y/no-noninteractive-tabindex -- focus the scroll box to read it with arrow keys.
        tabIndex={whole ? undefined : 0}
        hidden={!drawn}
      >
        {collapsible ? (
          <div ref={foldRef} className="cv-fold">
            {lines}
          </div>
        ) : (
          lines
        )}
      </div>
    </div>
  );
}

/// The nearest ancestor of `node` that scrolls: the one its sticky name sticks in.
function scrollerOf(node: HTMLElement): HTMLElement | undefined {
  const view = node.ownerDocument.defaultView;
  for (let at = node.parentElement; at; at = at.parentElement) {
    const overflow = view?.getComputedStyle(at).overflowY ?? "";
    if (overflow === "auto" || overflow === "scroll") return at;
  }
  return undefined;
}
