// An oversized paste's chip in the composer (pastedText.ts `isLargePaste`), in the strip and placed
// in the prompt alike: a compact row of a page glyph, the paste's first words and its label, which a
// click, Return or Space opens to the whole text. The opened view carries the paste's two ways on,
// Edit in Prompt (its text back in the draft) and Keep as .txt (sent as a file); Escape closes it.
// Leo, 2026-11-08, on the old card (a faded two-line page with its label cut mid-word and Keep as
// .txt laid over it): "this is really ugly and bad and normally in chatgpt you can just click it to
// expand or smth and maybe in claude you see it in a viewer?". Both openings were built and compared
// (gallery agent-pane.composer-paste-chip); the sheet ships (pastedTextChipModel.ts).
//
// The label never cuts a word and nothing sits on it: its parts ("Pasted text", "· 57 lines",
// "· 6.3K characters") are one line that wraps between parts and shows only its first row, so with
// too little room the size goes first, then the line count; the name always stays.
import { type ReactNode, useContext, useRef, useState } from "react";
import { Dialog } from "../../../ui/Dialog";
import { DialogButton } from "../../../ui/DialogButton";
import { Close, FileDoc } from "../conversation/icons";
import { usePaneLanguage, useT } from "../i18n";
import {
  LABEL_SEPARATOR,
  PASTE_CHIP_PREVIEW_CHARS,
  PasteChipDesignContext,
  pastedSizeParts,
} from "./pastedTextChipModel";
import { TEXT_CARD_LINES, textPreview } from "./textAttachmentCardModel";

/// Where the chip sits: the strip under the prompt, or placed in the prompt's text.
type Host = "strip" | "inline";

/// The host's own classes. The face keeps each host's open-button classes: the inline node view
/// (inlineNode.ts CHIP_FACE) lets a press on them drag the chip, and tests find the face by them.
const HOST = {
  strip: { chip: "acpmux-attachment acpmux-attachment-pasted", face: "acpmux-attachment-pasted-open" },
  inline: { chip: "acpmux-md-inline-chip", face: "acpmux-md-inline-retry acpmux-text-card__open" },
} as const;

export function PastedTextChip({
  host,
  text,
  name,
  accessibleName,
  remove,
  onEdit,
  onKeep,
}: {
  host: Host;
  text: string;
  /// The chip's name ("Pasted text").
  name: string;
  /// What the face is called to assistive tech: the paste's own name and the label.
  accessibleName: string;
  /// The host's × (shown on hover or focus).
  remove: ReactNode;
  /// Puts the text back in the prompt; unset where the composer cannot.
  onEdit?: () => void;
  /// Sends the text as a Pasted text.txt file instead; unset where the composer cannot attach one.
  onKeep?: () => void;
}) {
  const t = useT();
  const language = usePaneLanguage();
  const design = useContext(PasteChipDesignContext);
  const [open, setOpen] = useState(false);
  const face = useRef<HTMLButtonElement>(null);
  const parts = pastedSizeParts(t, language, text);
  const sheet = design !== "expand";
  /// An action closes the view first, then acts: the chip goes with either action.
  const act = (action: () => void) => () => {
    setOpen(false);
    action();
  };
  const actions = (
    <>
      {onKeep ? (
        <DialogButton
          dialogKey={null}
          className="ui-button ui-btn acpmux-attachment-keep-file"
          data-variant="subtle"
          data-size="md"
          onClick={act(onKeep)}
        >
          {t("composer.pastedText.keepFile")}
        </DialogButton>
      ) : null}
      {onEdit ? (
        <DialogButton
          dialogKey={null}
          className="ui-button ui-btn acpmux-paste-view__edit"
          data-variant={sheet ? "solid" : "subtle"}
          data-size="md"
          onClick={act(onEdit)}
        >
          {t("composer.pastedText.edit")}
        </DialogButton>
      ) : null}
    </>
  );
  const Chip = host === "inline" ? "span" : "div";
  return (
    <Chip
      className={`${HOST[host].chip} acpmux-paste-chip`}
      data-design={design}
      data-open={open ? "" : undefined}
      {...(host === "inline" ? { "data-state": "ready", "data-kind": "file", "data-preview": "text" } : {})}
      onKeyDown={
        sheet
          ? undefined
          : (event) => {
              if (event.key !== "Escape" || !open) return;
              event.preventDefault();
              event.stopPropagation();
              setOpen(false);
              face.current?.focus();
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
        onClick={() => setOpen((was) => (sheet ? true : !was))}
      >
        <span className="acpmux-paste-chip__glyph" aria-hidden="true">
          <FileDoc size={16} />
        </span>
        <span className="acpmux-paste-chip__body">
          {design === "tile" ? null : (
            // The old card's class names stay on the preview and the label: tests and gallery plays
            // read the paste's first words and its size by them.
            <span
              className="acpmux-paste-chip__preview acpmux-text-card__lines"
              data-wrap=""
              aria-hidden="true"
              dir="auto"
            >
              {textPreview(text, TEXT_CARD_LINES, PASTE_CHIP_PREVIEW_CHARS)}
            </span>
          )}
          <span className="acpmux-paste-chip__label acpmux-text-card__label" aria-hidden="true">
            <span className="acpmux-paste-chip__part" data-part="name">
              {name}
            </span>
            {parts.map((part, index) => (
              <span
                key={index}
                className="acpmux-paste-chip__part"
                data-part={index === parts.length - 1 ? "size" : "lines"}
              >
                <span className="acpmux-paste-chip__sep">{LABEL_SEPARATOR}</span>
                {part}
              </span>
            ))}
          </span>
        </span>
      </button>
      {remove}
      {sheet ? (
        <PastedTextSheet
          open={open}
          onOpenChange={setOpen}
          name={name}
          size={parts}
          text={text}
          closeLabel={t("image.close")}
        >
          {actions}
        </PastedTextSheet>
      ) : (
        <span className="acpmux-paste-chip__panel" aria-hidden={!open} inert={!open}>
          <span className="acpmux-paste-chip__panel-inner">
            {/* oxlint-disable-next-line jsx-a11y/no-noninteractive-tabindex -- focus the text's scroller to read it with the keys. */}
            <span className="acpmux-paste-view__text selectable" role="document" tabIndex={0} dir="auto">
              {open ? text : null}
            </span>
            <span className="acpmux-paste-view__actions">{actions}</span>
          </span>
        </span>
      )}
    </Chip>
  );
}

/// The whole paste in a sheet over the pane (the sheet role's glass, ui/popupSurface.css): its name
/// and size, the text in a scroller that takes focus (arrow keys and Page Down read on), then its
/// actions. Escape, a press outside or Close dismiss it, and focus goes back to the chip.
function PastedTextSheet({
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
