// The composer's side of a huge paste (pastedText.ts): it becomes a chip, unless Paste as Plain
// Text just ran (⌘⇧V or the prompt's menu), and a chip's click puts its text back in the prompt.
import { type RefObject, useEffect, useRef } from "react";
import type { ComposerAttachment } from "../attachments";
import type { MarkdownFieldHandle } from "../MarkdownField";
import type { MadeFile } from "./attachmentIntakeModel";
import { isLargePaste, PASTE_FILE_CHARS, PASTED_TEXT_NAME, pastedTextAttachment, pastedTextFile } from "../pastedText";
import { remember } from "./pasteMarks";

/// How long after Paste as Plain Text starts its paste still counts as that one: the menu's goes
/// through the host (`pane.edit`), which runs the web view's own paste. The prompt field keeps its
/// paste plain for the same window (MarkdownField.tsx `plainPasteAt`).
export const PLAIN_PASTE_MS = 2000;

/// Paste and Match Style's key (⌘⇧V, the app's Edit menu, MainMenu.swift). A system menu key
/// equivalent, not an app action: the bridge sends no keycap for it (shortcuts.ts), and the page
/// sees the key just before the web view's paste it starts. By the key's position too, so a
/// non-Latin layout (whose V key types another letter) counts.
export function isPasteAsPlainTextKey(event: KeyboardEvent): boolean {
  return (
    (event.key.toLowerCase() === "v" || event.code === "KeyV") &&
    event.metaKey &&
    event.shiftKey &&
    !event.altKey &&
    !event.ctrlKey
  );
}

export function usePastedChips(
  attachments: RefObject<ComposerAttachment[]>,
  setAttachments: (update: (current: ComposerAttachment[]) => ComposerAttachment[]) => void,
  field: RefObject<MarkdownFieldHandle | null>,
  /// Attaches a file the way a pasted file is (attachmentIntake.tsx): a paste past PASTE_FILE_CHARS
  /// goes as one. Unset, such a paste is a chip like any large one. `inText` false: the file stays in
  /// the strip and is never placed in the text.
  attachFile?: (file: MadeFile, inText?: boolean) => void,
) {
  /// Until when a paste goes in as it is: Paste as Plain Text just ran.
  const plainUntil = useRef(0);
  /// Set while a chip's text goes back into the prompt: that paste is never a chip.
  const expanding = useRef(false);
  /// How a held block pasted again opens its chip: the composer's own open (ComposerBox's inline
  /// hook), which keeps the chip for an undo first, as a click on the chip does. Unset, `expand`.
  const opens = useRef<((id: string) => void) | undefined>(undefined);
  /// The pastes that went into the draft as text (a chip's text put back too): the prompt sends
  /// each one still in it as pasted (pasteMarks.ts).
  const pastes = useRef<string[]>([]);
  // Any paste ends Paste as Plain Text's turn, one of only files or images too (the field took a
  // text paste before this, at the document, hears it).
  useEffect(() => {
    const ended = () => {
      plainUntil.current = 0;
    };
    document.addEventListener("paste", ended);
    return () => document.removeEventListener("paste", ended);
  }, []);
  /// Whether this paste goes in raw. Paste as Plain Text covers its one paste: the flag goes once
  /// the paste's task is done (a paste can ask twice, MarkdownField's pasteText).
  const raw = () => {
    if (expanding.current) return true;
    if (plainUntil.current < performance.now()) return false;
    queueMicrotask(() => {
      plainUntil.current = 0;
    });
    return true;
  };
  /// Puts chip `id`'s text back in the prompt, as a paste of it, and drops the chip: at the chip's
  /// place in the text, or at the caret when it has none.
  const expand = (id: string) => {
    const chip = attachments.current.find((held) => held.id === id);
    if (chip?.kind !== "pasted" || chip.text === undefined) return;
    // Ahead of the render, so a paste of the same block at once makes it a chip again.
    attachments.current = attachments.current.filter((held) => held.id !== id);
    setAttachments((current) => current.filter((held) => held.id !== id));
    field.current?.focus();
    // Its place in the text goes, and the caret with it, so its text goes in where the chip was
    // (composer/inlineAttachments.tsx), wherever the caret was before.
    field.current?.removeInline(id, true);
    expanding.current = true;
    try {
      field.current?.pasteText(chip.text);
    } finally {
      expanding.current = false;
    }
  };
  /// Sends chip `id`'s text as a file instead (Leo, 2026-11-07: "it just becomes this, like, .txt,
  /// kind of like an attachment"): the chip and its place in the prompt go, a Pasted text.txt comes.
  const keepAsFile = (id: string) => {
    const chip = attachments.current.find((held) => held.id === id);
    if (!attachFile || chip?.kind !== "pasted" || chip.text === undefined) return;
    // A chip with no place in the text (a paste made in a code block) waits in the strip: its file
    // waits there too. Placed at the caret, an undo would take the file out with no node of the
    // chip's to bring it back, and the paste would be gone from the draft.
    const inText = field.current?.inlineIds()?.includes(id) ?? true;
    attachments.current = attachments.current.filter((held) => held.id !== id);
    setAttachments((current) => current.filter((held) => held.id !== id));
    // The caret goes to where the chip was, so the file is placed there, wherever the caret was.
    field.current?.removeInline(id, true);
    attachFile({ name: PASTED_TEXT_NAME, type: "text/plain", file: pastedTextFile(chip.text) }, inText);
  };
  return {
    expanding,
    opens,
    pastes,
    /// Paste as Plain Text is starting: its paste goes in as text.
    plainPaste() {
      plainUntil.current = performance.now() + PLAIN_PASTE_MS;
    },
    /// Makes pasted `text` a chip when it is huge; true when it did. The same block pasted again
    /// while its chip is held does what a click on that chip does (`expand`): its text goes into the
    /// prompt and the chip goes, never a second chip (Leo, 2026-10-28: "double paste of long block
    /// text should reveal it instead of duplicating the paste", "if you paste that and then paste
    /// again, then you don't have to click it. It just does it.").
    take(text: string): boolean {
      // Past what a prompt carries it is a file, Paste as Plain Text or not.
      if (attachFile && text.length > PASTE_FILE_CHARS) {
        // Its tile shows now; its bytes are made a slice per task after (copying 100 MB of text in
        // the paste's own task held the page for 160 ms before the tile showed).
        attachFile({ name: PASTED_TEXT_NAME, type: "text/plain", file: pastedTextFile(text) });
        return true;
      }
      if (raw() || !isLargePaste(text)) {
        pastes.current = remember(pastes.current, text);
        return false;
      }
      const same = attachments.current.find((held) => held.kind === "pasted" && held.text === text);
      if (same) {
        (opens.current ?? expand)(same.id);
        return true;
      }
      const chip = pastedTextAttachment(text);
      // Ahead of the render, so a second paste at once counts this one.
      attachments.current = [...attachments.current, chip];
      setAttachments((current) => [...current, chip]);
      return true;
    },
    expand,
    /// Unset when the composer cannot attach a file.
    keepAsFile: attachFile ? keepAsFile : undefined,
  };
}
