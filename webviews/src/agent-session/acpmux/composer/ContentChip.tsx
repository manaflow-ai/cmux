// One chip for an attachment-like block of text: an oversized paste (PastedTextChip.tsx), an
// inspector pick (UIPickChip.tsx), and any other text insert that should read as one compact thing.
// A compact row of an icon, a first row (the content's first words, or a title made of parts) and a
// label of parts, which a click, Return or Space opens: in a viewer sheet over the pane, or in place
// under the face, with a Collapse control that folds it back (Escape too, focus back on the face).
// In the composer's strip, placed in the prompt's text, or in a sent message's body.
//
// The label never cuts a word and nothing sits on it: each row's parts are one line that wraps
// between parts and shows only its first row, so with too little room the parts drop from the end,
// whole; the first part always stays. The class names are the pasted text chip's, the first chip
// built this way (#38350): tests, gallery plays and the inline node view (inlineNode.ts) read them.
// Leo, 2026-11-08, on the inspector's pick: "clicking it should be able to show the raw/full
// thing... idk how possible it'd be to also be able to have a well-designed button to click to
// re-collapse it too."
import { type KeyboardEvent, type ReactNode, useRef, useState } from "react";
import { Dialog } from "../../../ui/Dialog";
import { DialogButton } from "../../../ui/DialogButton";
import { ChevronDown, Close } from "../conversation/icons";
import { useT } from "../i18n";
import { LABEL_SEPARATOR } from "./pastedTextChipModel";
import type { ChipAction, ChipHost, ChipLabelPart, ChipOpening } from "./contentChipModel";

/// The host's own classes. The face keeps each host's open-button classes: the inline node view
/// (inlineNode.ts CHIP_FACE) lets a press on them drag the chip, and tests find the face by them.
const HOST = {
  strip: { chip: "acpmux-attachment acpmux-attachment-pasted", face: "acpmux-attachment-pasted-open" },
  inline: { chip: "acpmux-md-inline-chip", face: "acpmux-md-inline-retry acpmux-text-card__open" },
  sent: { chip: "cv-user__chip", face: "cv-user__chip-open" },
} as const;

export function ContentChip({
  host,
  kind,
  design,
  opening,
  icon,
  preview,
  title,
  label,
  accessibleName,
  remove,
  text,
  sheetSize,
  actions = [],
  open: shownOpen,
  onOpenChange,
}: {
  host: ChipHost;
  /// What it holds (`paste`, `ui`), for its styles.
  kind: string;
  /// The design it draws (gallery comparisons), for its styles.
  design?: string;
  opening: ChipOpening;
  icon: ReactNode;
  /// The content's first words on one line, fading out at the chip's end (a paste's).
  preview?: string;
  /// The first row as parts (an inspector pick's element and snippet), in place of `preview`.
  title?: ChipLabelPart[];
  /// The second row; its first part always shows.
  label: ChipLabelPart[];
  /// What the face is called to assistive tech.
  accessibleName: string;
  /// The host's × (shown on hover or focus); none in a sent message.
  remove?: ReactNode;
  /// The whole content the opened view shows.
  text: string;
  /// The sheet's size line under its title (a paste's lines and characters).
  sheetSize?: string[];
  actions?: ChipAction[];
  /// Whether it is open, when the host keeps that (a sent message's disclosure, which outlives the
  /// row's mount and which Find opens); else the chip keeps it.
  open?: boolean;
  /// Told of each open and fold, the host's own `open` included.
  onOpenChange?: (open: boolean) => void;
}) {
  const t = useT();
  const [ownOpen, setOwnOpen] = useState(false);
  const open = shownOpen ?? ownOpen;
  const setOpen = (next: boolean) => {
    if (shownOpen === undefined) setOwnOpen(next);
    onOpenChange?.(next);
  };
  // The content stays drawn once opened, so folding it back shrinks a full panel, never an empty one.
  const [drawn, setDrawn] = useState(false);
  const face = useRef<HTMLButtonElement>(null);
  const sheet = opening.kind === "sheet";
  const collapse = opening.kind === "panel" ? opening.collapse : undefined;
  const fold = () => {
    setOpen(false);
    face.current?.focus();
  };
  const buttons = actions.map((action) => (
    <DialogButton
      key={action.id}
      dialogKey={null}
      className={`ui-button ui-btn ${action.className}`}
      data-variant={action.primary && sheet ? "solid" : "subtle"}
      data-size="md"
      onClick={() => {
        setOpen(false);
        action.onSelect();
      }}
    >
      {action.label}
    </DialogButton>
  ));
  const collapseButton = (
    <button type="button" className="acpmux-chip-collapse" data-place={collapse} data-find-skip="" onClick={fold}>
      <ChevronDown size={12} className="acpmux-chip-collapse__glyph" />
      <span>{t("composer.chip.collapse")}</span>
    </button>
  );
  const Chip = host === "strip" ? "div" : "span";
  return (
    <Chip
      className={`${HOST[host].chip} acpmux-paste-chip`}
      data-host={host}
      data-chip-kind={kind}
      data-design={design}
      data-opening={opening.kind}
      data-open={open ? "" : undefined}
      {...(host === "inline" ? { "data-state": "ready", "data-kind": "file", "data-preview": "text" } : {})}
      onKeyDown={
        sheet
          ? undefined
          : (event) => {
              if (event.key !== "Escape" || !open) return;
              event.preventDefault();
              event.stopPropagation();
              fold();
            }
      }
    >
      <button
        ref={face}
        type="button"
        className={`${HOST[host].face} acpmux-paste-chip__face`}
        aria-label={accessibleName}
        aria-haspopup={sheet ? "dialog" : undefined}
        aria-expanded={open}
        // Its rows are a label, not the content: Find counts the content and paints none here, so the
        // drawn matches keep Find's order (the file chip's face did the same).
        data-find-skip=""
        onClick={() => {
          setDrawn(true);
          setOpen(sheet ? true : !open);
        }}
      >
        <span className="acpmux-paste-chip__glyph" aria-hidden="true">
          {icon}
        </span>
        <span className="acpmux-paste-chip__body">
          {title ? (
            <Parts className="acpmux-paste-chip__title" parts={title} />
          ) : preview !== undefined ? (
            // The old card's class names stay on the preview: tests and gallery plays read the
            // paste's first words by them.
            <span
              className="acpmux-paste-chip__preview acpmux-text-card__lines"
              data-wrap=""
              aria-hidden="true"
              dir="auto"
            >
              {preview}
            </span>
          ) : null}
          <Parts className="acpmux-paste-chip__label acpmux-text-card__label" parts={label} />
        </span>
        {collapse === "chevron" ? (
          <span className="acpmux-paste-chip__chevron" aria-hidden="true">
            <ChevronDown size={12} />
          </span>
        ) : null}
      </button>
      {remove}
      {sheet ? (
        <ContentSheet
          open={open}
          onOpenChange={setOpen}
          name={label[0]?.text ?? accessibleName}
          size={sheetSize ?? []}
          text={text}
          closeLabel={t("image.close")}
        >
          {buttons}
        </ContentSheet>
      ) : (
        <span className="acpmux-paste-chip__panel" aria-hidden={!open} inert={!open}>
          <span className="acpmux-paste-chip__panel-inner">
            {collapse === "corner" ? collapseButton : null}
            {/* oxlint-disable-next-line jsx-a11y/no-noninteractive-element-interactions -- its keys only scroll the read-only text (readInEditor). */}
            <span
              className="acpmux-paste-view__text selectable"
              role="document"
              // oxlint-disable-next-line jsx-a11y/no-noninteractive-tabindex -- focus the text's scroller to read it with the keys.
              tabIndex={0}
              dir="auto"
              onKeyDown={host === "inline" ? readInEditor : undefined}
            >
              {open || drawn ? text : null}
            </span>
            {buttons.length || collapse === "footer" ? (
              <span className="acpmux-paste-view__actions">
                {collapse === "footer" ? collapseButton : null}
                {buttons}
              </span>
            ) : null}
          </span>
        </span>
      )}
    </Chip>
  );
}

/// The keys of an opened chip's text in the composer's editor (inlineNode.ts keeps the editor from
/// handling them): inside an editable field the browser reads the arrows as caret moves and never
/// scrolls a focused box, so the reading keys scroll it here; Enter, Backspace and typing do nothing
/// to the read-only text and never reach the draft. Escape (the chip folds), Tab and shortcuts
/// (Command-C copies the selected text) go on as they would.
const LINE_STEP = 40;
function readInEditor(event: KeyboardEvent<HTMLElement>) {
  if (event.key === "Escape" || event.key === "Tab" || event.metaKey || event.ctrlKey || event.altKey) return;
  const box = event.currentTarget;
  const page = Math.max(LINE_STEP, box.clientHeight - LINE_STEP);
  const step: Record<string, number> = {
    ArrowDown: LINE_STEP,
    ArrowUp: -LINE_STEP,
    PageDown: page,
    PageUp: -page,
    " ": event.shiftKey ? -page : page,
    Home: -box.scrollHeight,
    End: box.scrollHeight,
  };
  event.preventDefault();
  event.stopPropagation();
  const by = step[event.key];
  if (by !== undefined) box.scrollBy({ top: by });
}

/// A row of label parts: one line that wraps only between parts and shows only its first row.
function Parts({ className, parts }: { className: string; parts: ChipLabelPart[] }) {
  return (
    <span className={className} aria-hidden="true">
      {parts.map((part, index) => (
        <span key={index} className="acpmux-paste-chip__part" data-part={part.part} dir="auto">
          {index ? <span className="acpmux-paste-chip__sep">{LABEL_SEPARATOR}</span> : null}
          {part.text}
        </span>
      ))}
    </span>
  );
}

/// The whole content in a sheet over the pane (the sheet role's glass, ui/popupSurface.css): its name
/// and size, the text in a scroller that takes focus (arrow keys and Page Down read on), then its
/// actions. Escape, a press outside or Close dismiss it, and focus goes back to the chip.
function ContentSheet({
  open,
  onOpenChange,
  name,
  size,
  text,
  closeLabel,
  children,
}: {
  open: boolean;
  onOpenChange(open: boolean): void;
  name: string;
  /// The size's parts ("322 lines", "20.5K characters"): they wrap to a second row, never cut.
  size: string[];
  text: string;
  closeLabel: string;
  children: ReactNode;
}) {
  const body = useRef<HTMLDivElement>(null);
  return (
    <Dialog
      open={open}
      onOpenChange={onOpenChange}
      label={name}
      className="ui-glass ui-glass-floats acpmux-paste-view"
      initialFocus={body}
    >
      {/* React carries a portal's events up the chip's tree: a right-click or press in the sheet
          must not open the chip's menu or start a drag of it in the strip. */}
      {/* oxlint-disable-next-line jsx-a11y/no-static-element-interactions -- it only stops the sheet's events reaching the chip's handlers. */}
      <div
        className="acpmux-paste-view__content"
        onContextMenu={(event) => event.stopPropagation()}
        onPointerDown={(event) => event.stopPropagation()}
        onMouseDown={(event) => event.stopPropagation()}
      >
        <div className="acpmux-paste-view__bar">
          <span className="acpmux-paste-view__heading">
            <span className="acpmux-paste-view__title">{name}</span>
            <span className="acpmux-paste-view__size">
              {size.map((part, index) => (
                <span key={index} className="acpmux-paste-chip__part">
                  {index ? <span className="acpmux-paste-chip__sep">{LABEL_SEPARATOR}</span> : null}
                  {part}
                </span>
              ))}
            </span>
          </span>
          <button
            type="button"
            className="acpmux-image-viewer-action"
            aria-label={closeLabel}
            aria-keyshortcuts="Escape"
            onClick={() => onOpenChange(false)}
          >
            <Close />
          </button>
        </div>
        {/* oxlint-disable-next-line jsx-a11y/no-noninteractive-tabindex -- focus the text's scroller to read it with the keys. */}
        <div ref={body} className="acpmux-paste-view__text selectable" role="document" tabIndex={0} dir="auto">
          {text}
        </div>
        <div className="acpmux-paste-view__actions">{children}</div>
      </div>
    </Dialog>
  );
}
