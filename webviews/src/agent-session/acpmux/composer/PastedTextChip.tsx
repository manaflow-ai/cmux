// An oversized paste's chip in the composer (pastedText.ts `isLargePaste`), in the strip and placed
// in the prompt alike: a compact row of a page glyph, the paste's first words and its label, which a
// click, Return or Space opens to the whole text. The opened view carries the paste's two ways on,
// Edit in Prompt (its text back in the draft) and Keep as .txt (sent as a file); Escape closes it.
// Leo, 2026-11-08, on the old card (a faded two-line page with its label cut mid-word and Keep as
// .txt laid over it): "this is really ugly and bad and normally in chatgpt you can just click it to
// expand or smth and maybe in claude you see it in a viewer?". Both openings were built and compared
// (gallery agent-pane.composer-paste-chip); the sheet ships (pastedTextChipModel.ts).
//
// It is the content chip (ContentChip.tsx) with a paste's parts: its label ("Pasted text",
// "· 57 lines", "· 6.3K characters") drops the size, then the line count, when it has no room.
import { type ReactNode, useContext } from "react";
import { FileDoc } from "../conversation/icons";
import { usePaneLanguage, useT } from "../i18n";
import { ContentChip } from "./ContentChip";
import type { ChipAction } from "./contentChipModel";
import { PASTE_CHIP_PREVIEW_CHARS, PasteChipDesignContext, pastedSizeParts } from "./pastedTextChipModel";
import { UIPickDesignContext } from "./uiPickModel";
import { TEXT_CARD_LINES, textPreview } from "./textAttachmentCardModel";

export function PastedTextChip({
  host,
  text,
  name,
  accessibleName,
  remove,
  onEdit,
  onKeep,
}: {
  host: "strip" | "inline";
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
  // Opened in place, a paste folds back as an inspector pick does (one collapse control).
  const { collapse } = useContext(UIPickDesignContext);
  const parts = pastedSizeParts(t, language, text);
  const actions: ChipAction[] = [
    ...(onKeep
      ? [
          {
            id: "keep",
            label: t("composer.pastedText.keepFile"),
            className: "acpmux-attachment-keep-file",
            onSelect: onKeep,
          },
        ]
      : []),
    ...(onEdit
      ? [
          {
            id: "edit",
            label: t("composer.pastedText.edit"),
            className: "acpmux-paste-view__edit",
            primary: true,
            onSelect: onEdit,
          },
        ]
      : []),
  ];
  return (
    <ContentChip
      host={host}
      kind="paste"
      design={design}
      opening={design === "expand" ? { kind: "panel", collapse } : { kind: "sheet" }}
      icon={<FileDoc size={16} />}
      {...(design === "tile" ? {} : { preview: textPreview(text, TEXT_CARD_LINES, PASTE_CHIP_PREVIEW_CHARS) })}
      label={[
        { part: "name", text: name },
        ...parts.map((part, index) => ({ part: index === parts.length - 1 ? "size" : "lines", text: part })),
      ]}
      accessibleName={accessibleName}
      remove={remove}
      text={text}
      sheetSize={parts}
      actions={actions}
    />
  );
}
