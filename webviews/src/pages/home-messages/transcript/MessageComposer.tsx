// The Messages compose bar (MessagesLab Compose.swift with cmux's HomeNativeTranscriptView parts):
// the + attach button, the rounded Message field, the emoji button, the mic (dictation, when the host
// offers it) and Send. Return sends, Shift-Return adds a line.
//
// The rules the Swift view keeps:
// - Offline (H17, `isSendEnabled` false) Send is off and the text stays a draft: Return sends
//   nothing and says it waits to connect.
// - A send clears the field at once. A send the owner refuses before it is logged gives the text
//   back to an empty field (`restoreDraft`) with a notice above the field.
// - Up and Down recall the person's sent messages (history.ts): Up from the first line, Down from
//   the last.
// - Files attach from the + button, a paste or a drop (intake.ts rules); each uploads at once with
//   its progress in the tray above the field (the Channels plumbing, attachmentService.ts). A file
//   the data side cannot take is refused before it uploads, with a notice. Send waits for uploads.
import { useEffect, useImperativeHandle, useRef, useState, type Ref } from "react";
import { PromptEditor, type PromptEditorHandle } from "../../../agent-session/acpmux/composer/PromptEditor";
import { DictationButton } from "../../../agent-session/acpmux/DictationButton";
import { DictationNotice } from "../../../agent-session/acpmux/DictationNotice";
import { useDictation } from "../../../agent-session/acpmux/dictation";
import type { EmojiTable } from "../../../icon-picker/emojiData";
import { AttachmentTray, type PendingAttachment } from "../../home-channels/AttachmentViews";
import { attachmentClass, attachmentType, type AttachmentService } from "../../home-channels/attachmentService";
import { EmojiPicker, loadEmoji } from "../../home-channels/EmojiPicker";
import { HomeIcon } from "../../home-channels/icons";
import type { HomeAttachment } from "../../home-channels/types";
import type { Strings } from "../../shared/i18n";
import { useWebSwapHold } from "../../shared/useWebSwapHold";
import { ComposerHistory, historyTakesArrow } from "./history";
import { intakeProblem, textBeside, transferFiles, type TransferLike } from "./intake";

/** The host's call for dictation (`dictation.toggle`, `dictation.cancel`, ...), as the agent pane's. */
export type DictationCall = (method: string, params?: Record<string, unknown>) => Promise<unknown>;

export interface MessageComposerHandle {
  /** Files dropped on the transcript come here (the pane's drop target). */
  addFiles(files: Iterable<File>): void;
  focus(): void;
}

export interface MessageComposerProps {
  strings: Strings;
  /** False while the owner is unreachable: Send is off and the text stays a draft. */
  sendEnabled: boolean;
  /** True when the owner took the message (the store logged it); false gives the text back. */
  onSend(text: string, attachments?: readonly HomeAttachment[]): Promise<boolean>;
  /** Files upload to this conversation through this service; absent: no + and no file intake. */
  attachments?: { service: AttachmentService; conversation: string };
  /** The history's entries, newest first (`historyEntries`), read when a browse begins. */
  history?: () => string[];
  /** The host's dictation; absent: no mic (Debug Settings > Home > Mic button). */
  dictation?: DictationCall;
  /** The text the field starts with (a kept draft). */
  initialText?: string;
  /** The field's text changed (the host keeps the draft per conversation). */
  onDraftChange?(text: string): void;
  ref?: Ref<MessageComposerHandle>;
}

type Notice = { text: string; alert: boolean };

const noDictation: DictationCall = () => Promise.reject(new Error("no dictation"));

export function MessageComposer({
  strings,
  sendEnabled,
  onSend,
  attachments,
  history,
  dictation,
  initialText = "",
  onDraftChange,
  ref,
}: MessageComposerProps) {
  const { t } = strings;
  const [value, setValue] = useState(initialText);
  const [files, setFiles] = useState<readonly PendingAttachment[]>([]);
  const [notice, setNotice] = useState<Notice | undefined>();
  const [emoji, setEmoji] = useState<{ anchor: Element; table?: EmojiTable } | undefined>();
  const editor = useRef<PromptEditorHandle | null>(null);
  const picker = useRef<HTMLInputElement | null>(null);
  const uploads = useRef(new Map<string, AbortController>());
  const nextFile = useRef(1);
  const [browse] = useState(() => new ComposerHistory());
  const voice = useDictation(editor, dictation ?? noDictation);
  const ready = files.filter((item) => item.part).map((item) => item.part as HomeAttachment);
  const uploading = files.some((item) => !item.part && !item.error);
  const empty = !value.trim() && ready.length === 0;
  // WEB-SWAP: staged files live only in this composer (an upload aborts on unmount), so a web
  // update's reload waits for them to be sent or removed (pages/shared/webSwap.ts).
  useWebSwapHold(uploading ? "home.uploading" : files.length ? "home.attachments" : null);
  const canSend = sendEnabled && !empty && !uploading;

  const patchFile = (id: string, patch: Partial<PendingAttachment>) =>
    setFiles((current) => current.map((item) => (item.id === id ? { ...item, ...patch } : item)));

  const addFiles = (list: Iterable<File>) => {
    if (!attachments) return;
    const added: PendingAttachment[] = [];
    for (const file of list) {
      const problem = intakeProblem(file, t("home.composer.attach.pasted"));
      if (problem) {
        const key = problem.kind === "empty" ? "home.composer.attach.empty" : "home.composer.attach.refused";
        setNotice({ text: strings.format(key, problem.name), alert: true });
        continue;
      }
      const id = `f${nextFile.current++}`;
      added.push({ id, file, progress: { sent: 0, total: file.size } });
      // A small local picture while it uploads (a data URL: any page policy).
      if (attachmentClass(attachmentType(file) ?? "") === "image" && file.size <= 8_000_000) {
        const reader = new FileReader();
        reader.onload = () => typeof reader.result === "string" && patchFile(id, { thumb: reader.result });
        reader.readAsDataURL(file);
      }
      const controller = new AbortController();
      uploads.current.set(id, controller);
      attachments.service
        .upload(attachments.conversation, file, (progress) => patchFile(id, { progress }), controller.signal)
        .then(
          (part) => patchFile(id, { part }),
          () => {
            if (!controller.signal.aborted) patchFile(id, { error: t("home.composer.attach.failed") });
          },
        )
        .finally(() => uploads.current.delete(id));
    }
    if (added.length) setFiles((current) => [...current, ...added]);
  };
  const removeFile = (id: string) => {
    uploads.current.get(id)?.abort();
    setFiles((current) => current.filter((item) => item.id !== id));
  };
  // Every upload ends with the composer (another conversation makes a new one).
  useEffect(() => {
    const live = uploads.current;
    return () => {
      for (const controller of live.values()) controller.abort();
    };
  }, []);

  const setText = (text: string) => {
    setValue(text);
    onDraftChange?.(text);
  };

  const submit = (markdown: string) => {
    if (!sendEnabled) {
      // Offline: nothing goes, the text stays.
      if (markdown.trim() || ready.length) setNotice({ text: t("home.send.waitingToConnect"), alert: false });
      return;
    }
    if (uploading || (!markdown.trim() && ready.length === 0)) return;
    const sending = ready;
    const sentItems = files.filter((item) => item.part && sending.includes(item.part));
    browse.end();
    setNotice(undefined);
    setText("");
    editor.current?.reset("");
    if (sending.length) setFiles((current) => current.filter((item) => !item.part || !sending.includes(item.part)));
    // Refused before it was logged: the text comes back to an empty field and the files to the tray.
    const giveBack = () => {
      setValue((current) => {
        if (current) return current;
        onDraftChange?.(markdown);
        return markdown;
      });
      if (sentItems.length)
        setFiles((current) => [
          ...sentItems.filter((item) => !current.some((kept) => kept.id === item.id)),
          ...current,
        ]);
      setNotice({ text: t("home.send.refused.generic"), alert: true });
    };
    void onSend(markdown, sending.length ? sending : undefined).then((taken) => {
      if (!taken) giveBack();
    }, giveBack);
  };

  const recall = (direction: "older" | "newer"): boolean => {
    const field = editor.current;
    if (!field || !history) return false;
    const plain = field.text();
    if (plain.selectionStart !== plain.selectionEnd) return false;
    if (!historyTakesArrow(direction, plain.value, plain.selectionStart)) return false;
    const next = browse.step(direction, plain.value, history);
    if (next === undefined) return direction === "older" && browse.isBrowsing;
    field.writeText(next, next.length, next.length);
    return true;
  };

  const intake = (transfer: TransferLike, event: { preventDefault(): void }) => {
    if (!attachments) return;
    const list = transferFiles(transfer);
    if (list.length === 0) return;
    // Files attach; only the words beside them paste (a file's own name is not words).
    const words = textBeside(transfer);
    event.preventDefault();
    addFiles(list);
    if (words) editor.current?.insertTyped(words);
  };

  useImperativeHandle(ref, () => ({ addFiles, focus: () => editor.current?.focus() }));

  return (
    <div className="mt-compose" data-offline={sendEnabled ? undefined : "true"}>
      {notice && (
        <div className={`mt-notice${notice.alert ? " alert" : ""}`} role={notice.alert ? "alert" : "status"}>
          {notice.text}
        </div>
      )}
      {dictation && <DictationNotice dictation={voice} />}
      <AttachmentTray items={files} strings={strings} onRemove={removeFile} />
      <div className="mt-compose-bar">
        {attachments && (
          <>
            <button
              type="button"
              className="mt-plus"
              aria-label={t("compose.attach")}
              title={t("compose.attach")}
              onClick={() => picker.current?.click()}
            >
              <HomeIcon name="plus" />
            </button>
            <input
              ref={picker}
              type="file"
              multiple
              hidden
              aria-label={t("compose.attach")}
              onChange={(event) => {
                if (event.target.files) addFiles(event.target.files);
                event.target.value = "";
              }}
            />
          </>
        )}
        <div
          className="mt-field"
          onPasteCapture={(event) => intake(event.clipboardData, event)}
          onDropCapture={(event) => {
            event.stopPropagation();
            intake(event.dataTransfer, event);
          }}
        >
          <PromptEditor
            ref={editor}
            value={value}
            onChange={(markdown) => {
              browse.textChanged(editor.current?.text().value ?? markdown);
              setText(markdown);
              if (notice && !notice.alert) setNotice(undefined);
            }}
            onKeyDown={(event) => {
              if (event.shiftKey || event.altKey || event.metaKey || event.ctrlKey) return;
              if (event.key === "ArrowUp" && recall("older")) event.preventDefault();
              else if (event.key === "ArrowDown" && recall("newer")) event.preventDefault();
            }}
            onSubmit={(markdown, { cmd }) => (cmd ? undefined : submit(markdown))}
            placeholder={t("compose.placeholder")}
            attributes={{ "aria-label": t("compose.placeholder") }}
            features={{ multiline: true }}
            className="mt-field-editor"
          />
          <button
            type="button"
            className="mt-field-button"
            aria-label={t("compose.emoji")}
            title={t("compose.emoji")}
            onMouseDown={(event) => event.preventDefault()}
            onClick={(event) => {
              const anchor = event.currentTarget;
              setEmoji({ anchor });
              loadEmoji().then(
                (table) => setEmoji((open) => (open ? { ...open, table } : open)),
                () => setEmoji(undefined),
              );
            }}
          >
            <HomeIcon name="emoji" />
          </button>
          {dictation && <DictationButton dictation={voice} />}
        </div>
        {!empty && (
          <button
            type="button"
            className={`mt-send${canSend ? " ready" : ""}`}
            aria-label={t("home.compose.send")}
            title={t("home.compose.send")}
            disabled={!canSend}
            onClick={() => submit(editor.current?.value() ?? value)}
          >
            <HomeIcon name="send" />
          </button>
        )}
      </div>
      {emoji && (
        <EmojiPicker
          anchor={emoji.anchor}
          emoji={emoji.table}
          strings={strings}
          onPick={(text) => {
            setEmoji(undefined);
            editor.current?.focus();
            editor.current?.insertTyped(text);
          }}
          onClose={() => {
            setEmoji(undefined);
            editor.current?.focus();
          }}
        />
      )}
    </div>
  );
}

/** Whether a drag carries something the composer takes (files), so the pane highlights only then. */
export function dragOffersFiles(types: readonly string[]): boolean {
  return types.includes("Files");
}
