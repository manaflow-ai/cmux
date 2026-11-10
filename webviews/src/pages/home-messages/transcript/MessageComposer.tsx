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
// - While the Chief answers (`chief.working`), the emoji button is Stop (ChatController+Stop.swift): a
//   click stops the Chief's turn, Option-click stops all its agents. After a Stop, while nothing
//   runs, it is Continue (`chief.continueAvailable`): a click asks the Chief to go on with the turn.
// - The files are the conversation's (attachmentDrafts.ts, kept by the page): another conversation
//   showing leaves them, uploads and all, and coming back finds them in the tray.
import type { PrepareFile } from "./prepareAttachment";
import {
  useEffect,
  useImperativeHandle,
  useRef,
  useState,
  useSyncExternalStore,
  type ReactNode,
  type Ref,
} from "react";
import { PromptEditor, type PromptEditorHandle } from "../../../agent-session/acpmux/composer/PromptEditor";
import { elementBox, type ToastAvoidanceReports } from "../../../agent-session/acpmux/toastAvoidance";
import { DictationButton } from "../../../agent-session/acpmux/DictationButton";
import { DictationNotice } from "../../../agent-session/acpmux/DictationNotice";
import { isActive, useDictation } from "../../../agent-session/acpmux/dictation";
import { Icon } from "../../../agent-session/acpmux/icons/Icon";
import type { EmojiTable } from "../../../icon-picker/emojiData";
import { AttachmentTray, type PendingAttachment } from "../../home-channels/AttachmentViews";
import { attachmentClass, attachmentType, type AttachmentService } from "../../home-channels/attachmentService";
import { EmojiPicker, loadEmoji } from "../../home-channels/EmojiPicker";
import { HomeIcon } from "../../home-channels/icons";
import type { HomeAttachment } from "../../home-channels/types";
import type { Strings } from "../../shared/i18n";
import { useWebSwapHold } from "../../shared/useWebSwapHold";
import { quoteMarkdown } from "../../home-channels/quoteSelection";
import { useFileUndo } from "../../home-channels/useFileUndo";
import type { ComposerTarget } from "../composerHandoff";
import { AttachmentDrafts, type Upload } from "./attachmentDrafts";
import { ComposerHistory, historyTakesArrow } from "./history";
import { excerpt } from "./replyQuote";
import { intakeProblem, textBeside, transferFiles, type TransferLike } from "./intake";

/** The host's call for dictation (`dictation.toggle`, `dictation.cancel`, ...), as the agent pane's. */
export type DictationCall = (method: string, params?: Record<string, unknown>) => Promise<unknown>;

/** Files dropped on the transcript come here (the pane's drop target), and what the app hands over
 * (composerHandoff.ts): files by path, a quote of selected text. */
export interface MessageComposerHandle extends ComposerTarget {
  focus(): void;
}

export interface MessageComposerProps {
  strings: Strings;
  /** False while the owner is unreachable: Send is off and the text stays a draft. */
  sendEnabled: boolean;
  /** True when the owner took the message (the store logged it); false gives the text back. */
  onSend(text: string, attachments?: readonly HomeAttachment[]): Promise<boolean>;
  /** Files upload to this conversation through this service; absent: no + and no file intake.
   * `prepare`: what each file goes through first (the app's location removal, prepareAttachment.ts). */
  attachments?: { service: AttachmentService; conversation: string; prepare?: PrepareFile };
  /** The history's entries, newest first (`historyEntries`), read when a browse begins. */
  history?: () => string[];
  /** The host's dictation; absent: no mic (Debug Settings > Home > Mic button). */
  dictation?: DictationCall;
  /** The text the field starts with (a kept draft). */
  initialText?: string;
  /** The field's text changed (the host keeps the draft per conversation). */
  onDraftChange?(text: string): void;
  /** Where the files are kept per conversation (the page's); absent: this composer's own, which
   * end with it. */
  drafts?: AttachmentDrafts;
  /** The field's placeholder (a thread's composer says Reply); default: the conversation's. */
  placeholder?: string;
  /** The field checks spelling (Settings agentPane.spellChecking; off by default, as the setting). */
  spellChecking?: boolean;
  /** Reply to Selection's quote, shown in a card above the field (`name`: whose words; absent:
   * "Replying to Selection"); the send carries it (the caller's `onSend`). */
  quote?: { text: string; name?: string };
  onRemoveQuote?(): void;
  /** A Chief's turn controls (chiefTurn.ts): while it works the emoji button is Stop, and Escape
   * and Cmd-. in the field stop it; after a stop, Continue. Absent: the emoji button only. */
  chief?: ComposerChief;
  /** Over the field: the page's toast (Stop all agents' answer). */
  toast?: ReactNode;
  /** The host's toasts rest above this compose bar (its tray, notices and quote too): its box goes
   * to the host while it is mounted (detailHost.ts `homeToastAvoidance`). Absent: no host. */
  toastAvoidance?: ToastAvoidanceReports | undefined;
  ref?: Ref<MessageComposerHandle>;
}

/** What the composer's round button and keys do for a Chief (ChatController+Stop.swift). */
export interface ComposerChief {
  working: boolean;
  continueAvailable: boolean;
  /** Stop the Chief's turn; `all`: Stop all agents (Option-click). */
  onStop(all: boolean): void;
  onContinue(): void;
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
  drafts: kept,
  placeholder,
  spellChecking = false,
  quote,
  onRemoveQuote,
  chief,
  toast,
  toastAvoidance,
  ref,
}: MessageComposerProps) {
  const { t } = strings;
  const prompt = placeholder ?? t("compose.placeholder");
  const [value, setValue] = useState(initialText);
  // The page's drafts when it keeps them, else this composer's own (their uploads end with it).
  const [own] = useState(() => (kept ? undefined : new AttachmentDrafts()));
  const drafts = kept ?? own!;
  useEffect(() => () => own?.abortAll(), [own]);
  const tray = attachments?.conversation ?? "";
  const files = useSyncExternalStore(drafts.subscribe, () => drafts.files(tray));
  const hold = useSyncExternalStore(drafts.subscribe, drafts.holdReason);
  const [notice, setNotice] = useState<Notice | undefined>();
  const [emoji, setEmoji] = useState<{ anchor: Element; table?: EmojiTable } | undefined>();
  const editor = useRef<PromptEditorHandle | null>(null);
  const picker = useRef<HTMLInputElement | null>(null);
  /** The compose bar: Edit > Undo and Redo reach the editor inside it as `beforeinput`. */
  const barNode = useRef<HTMLDivElement | null>(null);
  // The app's toasts never cover the compose bar and never move it (Leo, 2026-11-07: "The composer
  // should never ever rise up because there's some sort of ... tooltip type thing"): the bar's box
  // goes to the host, which lifts its toasts above it, as the agent pane's (toastAvoidance.ts).
  const [bar, setBar] = useState<HTMLDivElement | null>(null);
  useEffect(() => (bar && toastAvoidance ? toastAvoidance.report(bar, elementBox) : undefined), [bar, toastAvoidance]);
  /** The files each hand-off group added, by group (a design card's files go back together). */
  const groups = useRef(new Map<string, string[]>());
  const [browse] = useState(() => new ComposerHistory());
  const voice = useDictation(editor, dictation ?? noDictation);
  const ready = files.filter((item) => item.part).map((item) => item.part as HomeAttachment);
  const uploading = files.some((item) => !item.part && !item.error);
  const empty = !value.trim() && ready.length === 0;
  // WEB-SWAP: a staged file the app does not keep yet (uploading, failed, or any in a composer
  // with no keeper) lives only in this page, so a web update's reload waits for it to finish, be
  // sent or be removed (pages/shared/webSwap.ts, attachmentDrafts.ts `holdReason`).
  useWebSwapHold(hold);
  const canSend = sendEnabled && !empty && !uploading;

  /** How `file` goes up: prepared by the app, then sent to the conversation. */
  const uploadFor =
    (file: File): Upload =>
    async (signal, progress, sending) => {
      if (!attachments) throw new Error("no attachments");
      const { service, conversation, prepare } = attachments;
      const ready = prepare ? await prepare(file, signal) : file;
      // The bytes that go are the ones kept (the app's preparation may have changed them).
      if (ready !== file) sending(ready);
      return service.upload(conversation, ready, progress, signal);
    };
  /** `items` as the tray has them now (a picture or upload that ended after the edit stays with them). */
  const current = (items: readonly PendingAttachment[]) => {
    const now = drafts.files(tray);
    return items.map((item) => now.find((each) => each.id === item.id) ?? item);
  };
  /// The staged files' adds and removes share Cmd-Z and Shift-Cmd-Z with the text (useFileUndo.ts).
  const fileUndo = useFileUndo(editor, barNode, {
    takeOut: (items) => {
      for (const item of items) drafts.remove(tray, item.id);
    },
    putBack: (items, index) => drafts.restore(tray, items, index, uploadFor, t("home.composer.attach.failed")),
    current,
  });

  const addFiles = (list: Iterable<File>, group?: string) => {
    if (!attachments) return;
    const { conversation } = attachments;
    const index = drafts.files(conversation).length;
    const added: string[] = [];
    for (const file of list) {
      const problem = intakeProblem(file, t("home.composer.attach.pasted"));
      if (problem) {
        const key = problem.kind === "empty" ? "home.composer.attach.empty" : "home.composer.attach.refused";
        setNotice({ text: strings.format(key, problem.name), alert: true });
        continue;
      }
      const id = drafts.add(conversation, file, uploadFor(file), t("home.composer.attach.failed"));
      added.push(id);
      // A small local picture while it uploads (a data URL: any page policy).
      if (attachmentClass(attachmentType(file) ?? "") === "image" && file.size <= 8_000_000) {
        const reader = new FileReader();
        reader.onload = () =>
          typeof reader.result === "string" && drafts.patch(conversation, id, { thumb: reader.result });
        reader.readAsDataURL(file);
      }
    }
    if (group) groups.current.set(group, [...(groups.current.get(group) ?? []), ...added]);
    if (added.length)
      fileUndo.noteFileEdit({
        kind: "add",
        items: drafts.files(conversation).filter((item) => added.includes(item.id)),
        index,
      });
  };
  const removeFile = (id: string) => {
    const index = drafts.files(tray).findIndex((item) => item.id === id);
    const item = drafts.files(tray)[index];
    if (!item) return;
    drafts.remove(tray, id);
    fileUndo.noteFileEdit({ kind: "remove", items: [item], index });
  };
  const removeGroup = (group: string): boolean => {
    const ids = groups.current.get(group);
    groups.current.delete(group);
    if (!ids?.length) return false;
    for (const id of ids) drafts.remove(tray, id);
    return true;
  };
  // Quote in Reply: the quote goes after what is typed, with a line for the reply, and typing goes on there.
  const quoteInReply = (text: string): boolean => {
    const markdown = quoteMarkdown(text);
    const field = editor.current;
    if (field?.quoteReply(markdown)) {
      field.focus();
      return true;
    }
    setText(value ? `${value.replace(/\s+$/, "")}\n\n${markdown}` : markdown);
    fileUndo.textWritten();
    return true;
  };

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
    browse.end();
    setNotice(undefined);
    setText("");
    editor.current?.reset("");
    // The editor's history starts over with the empty field: the file steps go with it.
    fileUndo.clear();
    const sentItems = sending.length ? drafts.take(tray, sending) : [];
    // Refused before it was logged: the text comes back to an empty field and the files to the tray.
    const giveBack = () => {
      setValue((current) => {
        if (current) return current;
        onDraftChange?.(markdown);
        return markdown;
      });
      if (sentItems.length) drafts.giveBack(tray, sentItems);
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

  useImperativeHandle(ref, () => ({
    takesFiles: !!attachments,
    addFiles,
    removeGroup,
    quote: quoteInReply,
    recallHistory: (direction) => {
      const field = editor.current;
      if (!field || !history) return false;
      field.focus();
      const next = browse.step(direction, field.text().value, history);
      if (next === undefined) return direction === "older" && browse.isBrowsing;
      field.writeText(next, next.length, next.length);
      return true;
    },
    focus: () => editor.current?.focus(),
  }));

  return (
    <div
      ref={(node) => {
        barNode.current = node;
        setBar(node);
      }}
      className="mt-compose"
      data-offline={sendEnabled ? undefined : "true"}
    >
      {toast}
      {notice && (
        <div className={`mt-notice${notice.alert ? " alert" : ""}`} role={notice.alert ? "alert" : "status"}>
          {notice.text}
        </div>
      )}
      {dictation && <DictationNotice dictation={voice} />}
      {quote && (
        <QuoteCard
          quote={quote}
          strings={strings}
          onRemove={() => {
            onRemoveQuote?.();
            editor.current?.focus();
          }}
        />
      )}
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
              fileUndo.textChanged();
              if (notice && !notice.alert) setNotice(undefined);
            }}
            onKeyDown={(event) => {
              if (fileUndo.keyDown(event)) return;
              // Escape and Cmd-. stop a working Chief (AppKit's cancelOperation), after the emoji
              // picker and dictation, which Escape ends first.
              const cancel =
                (event.key === "Escape" && !event.metaKey && !event.ctrlKey && !event.altKey) ||
                (event.key === "." && event.metaKey && !event.ctrlKey && !event.altKey);
              if (cancel && chief?.working && !emoji && !isActive(voice.state)) {
                event.preventDefault();
                chief.onStop(false);
                return;
              }
              if (event.shiftKey || event.altKey || event.metaKey || event.ctrlKey) return;
              if (event.key === "ArrowUp" && recall("older")) event.preventDefault();
              else if (event.key === "ArrowDown" && recall("newer")) event.preventDefault();
            }}
            onSubmit={(markdown, { cmd }) => (cmd ? undefined : submit(markdown))}
            placeholder={prompt}
            attributes={{ "aria-label": prompt, spellcheck: String(spellChecking) }}
            features={{ multiline: true }}
            className="mt-field-editor"
          />
          {chief?.working ? (
            <button
              type="button"
              className="mt-field-button mt-chief-stop"
              aria-label={t("compose.stop")}
              title={t("home.stop.toolTip")}
              onMouseDown={(event) => event.preventDefault()}
              onClick={(event) => chief.onStop(event.altKey)}
            >
              <Icon name="action.stop" selected size={14} />
            </button>
          ) : chief?.continueAvailable ? (
            <button
              type="button"
              className="mt-field-button mt-chief-continue"
              aria-label={t("home.compose.continue")}
              title={t("home.compose.continue")}
              onMouseDown={(event) => event.preventDefault()}
              onClick={() => chief.onContinue()}
            >
              <Icon name="media.play" selected size={14} />
            </button>
          ) : (
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
          )}
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

/** The quote a reply answers, on the message box (ReplyQuoteCardView): whose words, the words in
 * two lines at most, and a remove button. */
export function QuoteCard({
  quote,
  strings,
  onRemove,
}: {
  quote: { text: string; name?: string };
  strings: Strings;
  onRemove(): void;
}) {
  const title = quote.name
    ? strings.format("home.replyQuote.replyingTo", quote.name)
    : strings.t("home.replyQuote.replyingToSelection");
  const words = excerpt(quote.text);
  const remove = strings.t("home.replyQuote.remove");
  return (
    <div className="mt-quote-card">
      <span className="mt-quote-text">
        <span className="mt-quote-title">{title}</span>
        <span className="mt-quote-words">{words}</span>
      </span>
      <button type="button" className="mt-quote-remove" aria-label={remove} title={remove} onClick={onRemove}>
        <HomeIcon name="close" size={14} />
      </button>
    </div>
  );
}

/** Whether a drag carries something the composer takes (files), so the pane highlights only then. */
export function dragOffersFiles(types: readonly string[]): boolean {
  return types.includes("Files");
}
