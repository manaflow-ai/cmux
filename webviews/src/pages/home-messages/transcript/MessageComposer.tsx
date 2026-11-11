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
// - In a Chief chat, `/` at the message's start lists the Chief's skills (chiefSkills.ts, the native
//   SlashSkillMenu): typing filters them, Up and Down choose, Tab or Return (slashCommands.ts
//   returnPicks) or a click writes `/name ` over the word, Escape closes the list for that text.
//   While the list is on its way it says so, and a failed read says that, never an empty list.
// - The files are the conversation's (attachmentDrafts.ts, kept by the page): another conversation
//   showing leaves them, uploads and all, and coming back finds them in the tray.
import type { PrepareFile } from "./prepareAttachment";
import {
  useEffect,
  useId,
  useImperativeHandle,
  useMemo,
  useRef,
  useState,
  useSyncExternalStore,
  type ReactNode,
  type Ref,
} from "react";
import { PromptEditor, type PromptEditorHandle } from "../../../agent-session/acpmux/composer/PromptEditor";
import {
  returnPicks,
  shownName,
  useSlashNames,
  type SlashCommand,
  type SlashMatch,
  type SlashTrigger,
} from "../../../agent-session/acpmux/slashCommands";
import { Listbox } from "../../../ui/Listbox";
import { elementBox, type ToastAvoidanceReports } from "../../../agent-session/acpmux/toastAvoidance";
import { DictationButton } from "../../../agent-session/acpmux/DictationButton";
import { DictationNotice } from "../../../agent-session/acpmux/DictationNotice";
import { isActive, useDictation } from "../../../agent-session/acpmux/dictation";
import { Icon } from "../../../agent-session/acpmux/icons/Icon";
import type { EmojiTable } from "../../../icon-picker/emojiData";
import { AttachmentTray } from "../../home-channels/AttachmentViews";
import { attachmentClass, attachmentType, type AttachmentService } from "../../home-channels/attachmentService";
import { EmojiPicker, loadEmoji } from "../../home-channels/EmojiPicker";
import { HomeIcon } from "../../home-channels/icons";
import type { HomeAttachment } from "../../home-channels/types";
import type { Strings } from "../../shared/i18n";
import { useWebSwapHold } from "../../shared/useWebSwapHold";
import { quoteMarkdown } from "../../home-channels/quoteSelection";
import type { ComposerTarget } from "../composerHandoff";
import { AttachmentDrafts } from "./attachmentDrafts";
import {
  chiefSkillMatches,
  couldNameSkill,
  skillCommand,
  type ChiefSkillList,
  type ChiefSkills,
} from "./chiefSkills";
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
  /** What `/` lists (chiefSkills.ts); absent: no list. */
  skills?: ChiefSkills;
}

const NO_SKILLS: ChiefSkillList = { kind: "none" };
const noSkills = () => NO_SKILLS;
const noSubscribe = () => () => {};

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

  // The `/` list: the `/word` the caret ends (MarkdownField `onSlash`), the Chief's skills for it.
  const skillStore = chief?.skills;
  const skillList = useSyncExternalStore(skillStore?.subscribe ?? noSubscribe, skillStore?.getSnapshot ?? noSkills);
  const [slash, setSlashState] = useState<SlashTrigger | undefined>();
  const slashShown = useRef(false);
  const lastSlash = useRef<SlashTrigger | undefined>(undefined);
  const [slashActive, setSlashActive] = useState(0);
  const [arrowed, setArrowed] = useState(false);
  /** The text Escape closed the list on: it stays closed until the text changes. */
  const [dismissed, setDismissed] = useState<string | undefined>();
  const setSlash = (trigger: SlashTrigger | undefined) => {
    // A fresh `/` (none showed) reads the list; typing more never does, nor a message ↑ brought back.
    if (trigger?.leading && !slashShown.current && !browse.isBrowsing) skillStore?.load();
    slashShown.current = Boolean(trigger?.leading);
    // A new word forgets the row the arrows chose: the same word typed again picks by its spelling.
    if (lastSlash.current?.query !== trigger?.query || lastSlash.current?.leading !== trigger?.leading) {
      setSlashActive(0);
      setArrowed(false);
    }
    lastSlash.current = trigger;
    setSlashState(trigger);
  };
  const loadedSkills = skillList.kind === "loaded" ? skillList.skills : undefined;
  const skillCommands = useMemo(() => loadedSkills?.map(skillCommand), [loadedSkills]);
  const slashNames = useSlashNames(skillCommands);
  // A message ↑ brought back keeps its arrows for history: a `/skill` in it opens no list.
  const typedSlash =
    skillStore && slash?.leading && dismissed !== value && !browse.isBrowsing ? slash : undefined;
  const menuId = useId();
  const slashRows = useMemo(
    () => (typedSlash && loadedSkills ? chiefSkillMatches(loadedSkills, typedSlash) : []),
    [typedSlash, loadedSkills],
  );
  // A status row (loading, failed, none) only while the word can still name a skill: never for a path.
  const slashStatus =
    !typedSlash || skillList.kind === "none" || !couldNameSkill(typedSlash.query)
      ? undefined
      : skillList.kind === "loading"
        ? t("home.compose.slash.loading")
        : skillList.kind === "failed"
          ? t("home.compose.slash.failed")
          : skillList.skills.length === 0
            ? t("home.compose.slash.none")
            : undefined;
  // A `/word` no skill names is the person's text (`/tmp/x is broken`): no list.
  const slashOpen = typedSlash !== undefined && (slashRows.length > 0 || slashStatus !== undefined);
  const slashSelected = Math.min(slashActive, Math.max(0, slashRows.length - 1));
  const pickSkill = (command: SlashCommand) => {
    const name = shownName(command);
    if (!editor.current?.insertCommand(name)) {
      const next = `/${name} `;
      setText(next);
      editor.current?.writeText(next, next.length, next.length);
    }
    setSlashState(undefined);
    lastSlash.current = undefined;
    slashShown.current = false;
    editor.current?.focus();
  };
  /** The list's keys, before the field's own: true when the list took the key. */
  const slashKey = (event: KeyboardEvent): boolean => {
    if (!slashOpen || event.shiftKey || event.altKey || event.metaKey || event.ctrlKey) return false;
    const row = slashRows[slashSelected];
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      if (slashRows.length === 0) return false;
      const step = event.key === "ArrowDown" ? 1 : -1;
      setSlashActive((slashSelected + step + slashRows.length) % slashRows.length);
      setArrowed(true);
    } else if (event.key === "Tab" && row) pickSkill(row.command);
    else if (event.key === "Enter" && returnPicks(row, typedSlash?.query ?? "", arrowed) && row) pickSkill(row.command);
    else if (event.key === "Escape") setDismissed(value);
    else return false;
    event.preventDefault();
    return true;
  };

  const addFiles = (list: Iterable<File>, group?: string) => {
    if (!attachments) return;
    const { service, conversation, prepare } = attachments;
    const added: string[] = [];
    for (const file of list) {
      const problem = intakeProblem(file, t("home.composer.attach.pasted"));
      if (problem) {
        const key = problem.kind === "empty" ? "home.composer.attach.empty" : "home.composer.attach.refused";
        setNotice({ text: strings.format(key, problem.name), alert: true });
        continue;
      }
      const id = drafts.add(
        conversation,
        file,
        async (signal, progress, sending) => {
          const ready = prepare ? await prepare(file, signal) : file;
          // The bytes that go are the ones kept (the app's preparation may have changed them).
          if (ready !== file) sending(ready);
          return service.upload(conversation, ready, progress, signal);
        },
        t("home.composer.attach.failed"),
      );
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
  };
  const removeFile = (id: string) => drafts.remove(tray, id);
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
    <div ref={setBar} className="mt-compose" data-offline={sendEnabled ? undefined : "true"}>
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
      {slashOpen && (
        <SkillMenu
          id={menuId}
          rows={slashRows}
          active={slashSelected}
          status={slashStatus}
          loading={skillList.kind === "loading"}
          strings={strings}
          onHover={setSlashActive}
          onPick={pickSkill}
          sourceOf={(name) => loadedSkills?.find((skill) => skill.name === name)?.source}
        />
      )}
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
            slashNames={slashNames}
            onSlash={setSlash}
            onKeyDown={(event) => {
              if (event.isComposing || event.keyCode === 229) return;
              // The `/` list takes its keys first (Escape closes it before it stops the Chief).
              if (slashKey(event)) return;
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
            attributes={{
              "aria-label": prompt,
              spellcheck: String(spellChecking),
              ...(skillStore
                ? {
                    role: "combobox",
                    "aria-autocomplete": "list",
                    "aria-expanded": String(slashOpen),
                    "aria-controls": slashOpen ? menuId : undefined,
                    "aria-activedescendant":
                      slashOpen && slashRows.length > 0 ? `${menuId}-${slashSelected}` : undefined,
                  }
                : {}),
            }}
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

/** The `/` list over the message box: `/name` with the typed letters marked, where the skill comes
 * from, its description; or one status row while the list loads, failed, or the Chief has none. */
function SkillMenu({
  id,
  rows,
  active,
  status,
  loading,
  strings,
  onHover,
  onPick,
  sourceOf,
}: {
  id: string;
  rows: SlashMatch[];
  active: number;
  status: string | undefined;
  loading: boolean;
  strings: Strings;
  onHover(index: number): void;
  onPick(command: SlashCommand): void;
  sourceOf(name: string): string | undefined;
}) {
  const { t } = strings;
  const sourceLabel = (source: string | undefined) =>
    source === "claude"
      ? t("home.compose.slash.source.claude")
      : source?.startsWith("plugin:")
        ? source.slice("plugin:".length)
        : t("home.compose.slash.source.chief");
  if (rows.length === 0)
    return (
      <div id={id} className="ui-popup ui-glass mt-slash-menu mt-slash-status" role="status" aria-busy={loading}>
        {status}
      </div>
    );
  return (
    <Listbox
      items={rows}
      getKey={(row) => row.command.name}
      textValue={(row) => shownName(row.command)}
      label={t("home.compose.slash.label")}
      autoFocus={false}
      activeIndex={active}
      onActiveIndexChange={onHover}
      onOpen={(row) => onPick(row.command)}
      getItemId={(_, index) => `${id}-${index}`}
      className="ui-popup ui-glass mt-slash-menu"
      id={id}
      rowClassName="mt-slash-row"
      renderItem={(row) => (
        <>
          <span className="mt-slash-name">
            /<Marked name={shownName(row.command)} ranges={row.ranges} />
          </span>
          <span className="mt-slash-source">{sourceLabel(sourceOf(row.command.name))}</span>
          <span className="mt-slash-description">{row.command.description}</span>
        </>
      )}
    />
  );
}

function Marked({ name, ranges }: { name: string; ranges: [number, number][] }) {
  const parts: ReactNode[] = [];
  let at = 0;
  for (const [start, end] of ranges) {
    if (start > at) parts.push(name.slice(at, start));
    parts.push(<mark key={start}>{name.slice(start, end)}</mark>);
    at = end;
  }
  if (at < name.length) parts.push(name.slice(at));
  return <>{parts}</>;
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
