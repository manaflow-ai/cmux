import React, { useCallback, useEffect, useImperativeHandle, useLayoutEffect, useMemo, useRef, useState } from "react";
import { createPortal } from "react-dom";
// Send's iMessage colors (--cmux-messages-blue); build-agent-pane-web.sh inlines the sheet.
import "../../theme/messages.css";
import type { ConnectKind, OffloadKind } from "./environments";
import type { RunModeRows } from "./sandboxRun";
import { useEscapingList } from "../../ui/popupHost";
import { ComposerListLayer, useComposerListBox } from "./backdropLayer";
import type { AcpmuxSnapshot, QueueEdit } from "./model";
import {
  bindMarks,
  placeInline,
  withoutInlineTokens,
  type AttachmentError,
  type ComposerAttachment,
  type DroppedKind,
  type LinkItem,
} from "./attachments";
import { awaitsOriginals } from "./promptBudget";
import type { UploadProgressReport, UploadResult } from "./cloudUploads";
import { cappedShellChips, shellAttachment, type ShellRun } from "./shell/shellRuns";
import { opensProcessTerminal } from "./processTerminal";
import type { Project } from "./ProjectChooser";
import { ComposerContext } from "./ComposerContext";
import { showsLocationRow } from "./locationRow";
import { createUnsentDraftThrottle, type UnsentDraftThrottle } from "./unsentDraftThrottle";
import { ComposerQueue } from "./ComposerQueue";
import { ownQueue } from "./conversation/queuedMessages";
import { ArrowUpIcon, BuildIcon, ContextRing, PlanIcon, ReturnIcon, StopIcon } from "./ComposerPickers";
import { FileSearch } from "./FileSearch";
import { PromptFocus } from "./promptFocus";
import { ComposerBox, type ComposerBoxHandle } from "./ComposerBox";
import { Spinner } from "./conversation/icons";
import { markdownOffset, MentionMenu, mentionQuery, mentionResults, useMentionSearch } from "./MentionMenu";
import {
  hasOtherChats,
  loadRecentMentionPaths,
  mentionInsert,
  mentionItems,
  mentionSelection,
  recentMentionScope,
  rememberMentionPath,
  type MentionItem,
} from "./mentionItems";
import type { ContextMenuItem } from "../../ui/ContextMenu";
import { openChipMenu } from "./composerChipMenu";
import type { Choice } from "./ComposerPickers";
import type { FileSearchSource } from "./fileSearchModel";
import {
  CMUX_PASS_THROUGH,
  CmuxCommandRefused,
  composerCommand,
  harnessTakesToo,
  type CmuxCommand,
  type CmuxCommandResult,
} from "./cmuxCommands";
import {
  applyCommand,
  fastModeState,
  isFastCommand,
  shownName,
  slashMatches,
  useSlashNames,
  withSkillDollars,
  withoutSkillDollars,
  type SlashCommand,
  type SlashMatch,
  type SlashTrigger,
} from "./slashCommands";
import { commandWaitsForTurn } from "./cliOnlyCommands";
import { BoltIcon } from "./BoltIcon";
import {
  cachePersistedDraft,
  draftHistory,
  draftWasRead,
  flushPendingDraftWrites,
  forgetQueuedDraft,
  hydratedDraft,
  lastQueuedDraftText,
  markDraftRead,
  draftFits,
  mergedDraft,
  noteDraftEdited,
  noteDraftHeld,
  noteDraftKeptApart,
  noteDraftSent,
  readDurableDraftState,
  readPersistedDraft,
  settlePendingDraftWrites,
  useDraftActionsVersion,
  writePersistedDraft,
} from "./composerDraft";
import type { MarkdownFieldHandle, MarkdownFieldProps } from "./MarkdownField";
import { type StringKey, useT } from "./i18n";
import { remoteComposer } from "./remoteEditing";
import { useComposerChrome } from "./composerChrome";
import { useQueueing } from "./queueing";
import { useMenuPressGuard } from "./menuPressGuard";
import { setScrollToBottomOnSend, useComposerSettings } from "./composerSettings";
import { useComposerLook } from "./composerLook";
import { LookSwitch } from "./LookSwitch";
import { useEscapeStop } from "./escapeStop";
import { usePromptHistory } from "./composer/promptHistory";
import {
  appendAttachments,
  attachmentErrorText,
  useAttachmentIntake,
  useSendWhenAttached,
  useSendWhenOriginals,
} from "./composer/attachmentIntake";
import { keepElsewhere, type KeptAttachments, useKeptAttachments } from "./composer/keptAttachments";
import { holdWebSwap, takeWebSwapFocus, WEB_SWAP_FOCUS, WEB_SWAP_KEPT_TEXT } from "../../pages/shared/webSwap";
import { usePasteAnywhere } from "./composer/pasteAnywhere";
import { DropOverlay } from "./composer/DropOverlay";
import type { SendBlock } from "./useFolderTrustAsk";
import { folder, promptSuggestion, type LivePullRequest, type PromptSuggestion } from "./promptSuggestion";
import { useHeaderState } from "./header/headerState";
import { queuePauseReason } from "./queuePause";
import { stopTurnFromAction } from "./stopTurnAction";
import { composerPlusRegistry, type ComposerPlusExtension } from "./composerPlusRegistry";
import { ComposerPlusMenu } from "./ComposerPlusMenu";
import { loadRecentCommandNames, recentCommands, rememberRecentCommand } from "./recentCommands";
import { openPicker } from "./pickerOpeners";

/// Composer copy. English defaults until the host passes localized labels, as the rest of the pane does today.
/// How long after a send the Stop button that replaces Send ignores clicks.
const STOP_GUARD_MS = 600;

/// How often at most a new chat's text goes to the host while the person types (`onUnsentDraft`).
const UNSENT_DRAFT_INTERVAL_MS = 300;
/// A field change this soon after the person's key, text input or composition is their edit.
const TYPED_WINDOW_MS = 250;
/// With Cmd held, the keys that edit the prompt (undo, redo, cut, paste, delete a line); any other
/// Cmd chord (select all, copy, a shortcut) changes nothing the person typed.
const CMD_EDIT_KEYS = new Set(["z", "y", "x", "v", "Backspace", "Delete"]);
/// With Control held, those and macOS's text-editing keys: Ctrl-H deletes back, Ctrl-D forward,
/// Ctrl-K to the line's end, Ctrl-Y yanks it back, Ctrl-T transposes, Ctrl-O opens a line.
const CTRL_EDIT_KEYS = new Set([...CMD_EDIT_KEYS, "h", "d", "k", "t", "o"]);
/// Keys that move, leave or modify, never edit: a change after one is not typing.
const NOT_AN_EDIT_KEY = new Set([
  "ArrowUp",
  "ArrowDown",
  "ArrowLeft",
  "ArrowRight",
  "Home",
  "End",
  "PageUp",
  "PageDown",
  "Escape",
  "Tab",
  "Shift",
  "Meta",
  "Alt",
  "Control",
  "CapsLock",
]);

export type ComposerEditCommand = "cut" | "copy" | "paste" | "pasteAsPlainText";

export const COMPOSER_LABELS = {
  placeholder: "composer.placeholder",
  placeholderQueued: "composer.placeholderQueued",
  placeholderSteer: "composer.placeholderSteer",
  suggestFailing: "composer.suggestFailing",
  suggestDraft: "composer.suggestDraft",
  suggestOpen: "composer.suggestOpen",
  suggestionKey: "composer.suggestionKey",
  suggestionHint: "composer.suggestionHint",
  placeholderSteerQuick: "composer.placeholderSteerQuick",
  add: "composer.add",
  mention: "composer.mention",
  attach: "composer.attach",
  attachScreenshot: "composer.attachScreenshot",
  attachWindow: "composer.attachWindow",
  prompt: "composer.prompt",
  send: "composer.send",
  stop: "composer.stop",
  stopping: "composer.stopping",
  escapeAgainToStop: "composer.escapeAgainToStop",
  commands: "composer.commands",
  noCommands: "composer.noCommands",
  noMatchingCommands: "composer.noMatchingCommands",
  attachments: "composer.attachments",
  removeAttachment: "composer.removeAttachment",
  openAttachment: "composer.openAttachment",
  dropFiles: "composer.dropFiles",
  sentAsFileForCodex: "composer.sentAsFileForCodex",
  tooLarge: "composer.tooLarge",
  unsupported: "composer.unsupported",
  imagesUnsupported: "composer.imagesUnsupported",
  cut: "composer.menu.cut",
  copy: "composer.menu.copy",
  paste: "composer.menu.paste",
  pasteAsPlainText: "composer.menu.pasteAsPlainText",
  undo: "composer.menu.undo",
  redo: "composer.menu.redo",
  selectAll: "composer.menu.selectAll",
  attachFiles: "composer.menu.attachFiles",
  insertMention: "composer.menu.insertMention",
  scrollToBottomOnSend: "composer.menu.scrollToBottomOnSend",
} as const satisfies Record<string, StringKey>;

/// What the pane can do to the composer from outside it.
export type ComposerHandle = {
  /// Reads the current prompt and attachments before the composer is swapped out.
  draft(): { text: string; attachments: ComposerAttachment[] };
  /// Puts a held-back prompt in: `text` before what is typed now, `attachments` before the rest.
  restore(text: string, attachments: ComposerAttachment[]): void;
  /// Snapshot the unsent text without attachment markers or taking it out of this chat.
  draftText(): string;
  /// Prevent ordinary session-switch attachment handoff for text-only recovery.
  suppressAttachmentCarryFor(sessionId?: string): void;
  clearAttachmentCarrySuppression(): void;
  /// Adds a chip after the ones held, leaving the prompt as typed (the floating chat's Include
  /// focused tab); one with the same id is replaced. Nothing changes when it holds the most it can.
  attach(attachment: ComposerAttachment): void;
  /// Adds a chip the host is still making (a long dictation recording it sends to the chat's
  /// machine): a pending tile a send waits for, which becomes the chip `make` answers, or fails with
  /// `failure` and Retry; the send keeps waiting until Retry makes it or its × takes it out
  /// (composer/attachmentIntake.tsx attachLater). Its × runs `stop`.
  attachLater(
    name: string,
    make: () => Promise<ComposerAttachment | undefined>,
    failure: string,
    stop?: () => void,
  ): void;
  /// Takes out the chips with these ids, leaving the prompt as typed (a design mode highlight removed on the page).
  detach(ids: readonly string[]): void;
  /// Sends what is typed now, as Enter would, even while a trust `blocked` reason is still drawn
  /// (the user just answered Trust). A pending folder choice still holds it. False when nothing went.
  send(): boolean;
  /// Puts the caret in the prompt (Edit and Resend).
  focus(): void;
  /// Starts the prompt with `prefix` (the palette's Side Question writes `/btw `), keeping what is
  /// typed after it, and puts the caret at the end. A prompt that already starts with it only
  /// takes focus.
  prefill(prefix: string): void;
  /// Quote in Reply: append after the draft, regardless of focus, ready to type below it.
  quoteReply(markdown: string): void;
  /// What it holds that acpmux's draft does not, for a page about to let go (`pane.wakeState`):
  /// file chips and shell mode's unrun command. Shell runs and move chips stay with their page.
  wakeState(): ComposerWake;
  /// Sends the typed text now and resolves once the host holds it: acpmux's draft for a chat with
  /// a session, `chat.unsentDraft` (its 300 ms throttle flushed) for a new chat. Asked before a quit.
  settleDraft(): Promise<void>;
  /// Puts back what a released page's composer held (the handshake's `wake`).
  wake(state: ComposerWake): void;
};

export type ComposerWake = {
  attachments?: ComposerAttachment[];
  shell?: boolean;
  shellText?: string;
};

type Props = {
  snapshot: AcpmuxSnapshot;
  /// The native tab's folder, which the header's PR chip describes. A fresh chat's folder pick
  /// (`projectDraft`) moves `snapshot`'s cwd but not the tab's until the chat starts, so the
  /// header's PR belongs to another folder then.
  headerCwd?: string;
  chips: React.ComponentType<{ snapshot: AcpmuxSnapshot }>;
  /// Sends a prompt. False when nothing can take it yet (no acpmux), so the prompt keeps it. A
  /// promise holds the prompt in the composer until the host takes it: it clears when the promise
  /// resolves and stays (for the user to send again) when it rejects, so a refusal loses nothing.
  /// `steer`: into the running turn now (⌘Return); otherwise a prompt sent mid-turn waits behind it.
  onSend(text: string, attachments?: ComposerAttachment[], steer?: boolean): boolean | void | Promise<unknown>;
  onStop(): void;
  /// Withdraws a queued prompt (`_acpmux/queue_remove`); false when it already started.
  onQueueRemove?(promptId: string): Promise<boolean>;
  /// Pulls a queued prompt back into the composer, retaining its text and attachments.
  onQueueCancelEdit?(promptId: string, text: string, attachments: ComposerAttachment[]): Promise<boolean>;
  /// Changes a queued prompt (`_acpmux/queue_edit`): its text, its place, or send it now.
  onQueueChange?(promptId: string, edit: QueueEdit): Promise<boolean>;
  /// The text of an edit whose prompt started meanwhile: it goes back in the prompt.
  onQueueLost?(text: string, promptId: string): void;
  /// Reads an image a queued prompt sends by its acpmux id, as a data URL (`_acpmux/attachment`).
  /// Stable: each queued thumbnail reads once.
  queueImage?(id: string): Promise<string | undefined>;
  /// Asks a queued prompt in a new side chat and withdraws it (the queued row's Open in side chat);
  /// absent where the chat opens no side chat.
  onQueueSideChat?(promptId: string, prompt: string): Promise<boolean>;
  /// Text the prompt starts with, such as what a chat opened from another tab inherited.
  /// Each new value fills an empty prompt once, caret at the end; it is never sent by itself.
  draft?: string;
  /// The durable session whose unsent prompt belongs in this composer.
  sessionId?: string;
  /// A harness switch is under way (another provider's model was picked): the session changes
  /// under the prompt, and the typed text stays instead of the new session's empty draft.
  switching?: boolean;
  /// False while the pane does not yet know which chat it shows (locationRow.ts paneKnowsNewChat):
  /// an existing chat being restored or opened draws no location strip. Unset: known.
  chatKnown?: boolean;
  /// The bar's left button, such as attach; by default + opens the agent's commands. `null` leaves the slot empty.
  leading?: React.ReactNode;
  /// Buttons before Send, such as the dictation mic.
  accessory?: React.ReactNode;
  /// A dictation session is waiting for words: the empty prompt reads "Listening…" in italic.
  dictating?: boolean;
  /// Also receives the prompt field's handle, for dictation, which writes into it as typing does.
  prompt?: React.RefObject<MarkdownFieldHandle | null>;
  /// Receives the composer's handle, which puts a prompt a harness switch held back (its text
  /// and attachments) into the composer.
  handle?: React.Ref<ComposerHandle>;
  /// Quotes the composer took (`quoteReply`) while its editor was still being made, when it goes
  /// before the editor is: the host holds them for the next composer, so none is lost.
  onUnplacedQuotes?(quotes: string[]): void;
  /// The context menu's Cut, Copy, Paste and Paste as Plain Text: the host runs the web view's own
  /// editing command (`pane.edit`). Without it those items are disabled.
  onEdit?(command: ComposerEditCommand): void;
  /// Handles a cmux-owned slash command after the user submits it. False keeps the prompt; a
  /// promise keeps the text until it resolves; accepted commands consume their attachments immediately.
  /// `CMUX_PASS_THROUGH` hands the prompt to the normal send path (onSend), attachments and steer included.
  onCmuxCommand?(command: CmuxCommand, args?: string): CmuxCommandResult;
  /// The empty prompt's text in place of the usual one (a side session's "Reply in this session…").
  placeholder?: string;
  /// A new chat's typed text, before it has a session (acpmux keeps a session's draft): the host
  /// keeps it with the tab, so a relaunch opens the chat with it (cx-z5vd).
  onUnsentDraft?(text: string): void | Promise<unknown>;
  /// The person edited the prompt of a chat that has a session: the pane tells acpmux it types
  /// (multiplayer). A draft coming back is not an edit.
  onTyping?(text: string, sessionId?: string): void;
  /// Where the host keeps the chat's unsent chips, so they come back when the chat shows again.
  keptAttachments?: KeptAttachments;
  /// Reads a transcript chosen by the cmux-owned `/import` command.
  onImportFile?(file: File): void | Promise<void>;
  /// The selected New Chat mode is Sandboxed. Transcript import creates a persistent chat, so
  /// refuse it while this mode is active instead of bypassing the sandbox send path.
  importSandboxed?: boolean;
  /// Searches the session's files; the + menu offers Search files only when set.
  searchFiles?: FileSearchSource;
  plusExtensions?: readonly ComposerPlusExtension[];
  onPlusCommand?(id: string): void;
  /// The + menu's Attach Screenshot… and Attach Window… (cx-ncc.71): the host's capture of a region
  /// or a window, attached as an image; an error for one too large to attach (shown as the
  /// composer's note); undefined when the person cancelled the pick.
  capture?(mode: "screen" | "window"): Promise<File | AttachmentError | undefined>;
  /// Saves dropped, pasted or chosen files the composer can't attach where the agent reads them (a
  /// moved chat's machine, or this Mac): each becomes a chip that sends its path. Undefined when this
  /// chat takes none.
  upload?(
    files: File[],
    cancelled?: (index: number) => boolean,
    progress?: UploadProgressReport,
  ): Promise<UploadResult>;
  /// For a chat on this Mac: where the files of the person's drop or paste are, so a folder or a file
  /// no block takes goes as a link to it, with nothing copied (composer/intakeFiles.ts droppedPaths).
  localPaths?(kind: DroppedKind, files: File[]): Promise<LinkItem[] | undefined>;
  /// Starts a new chat in another project; the tray's project pill chooses only when set.
  onProject?(cwd: string, peer?: string): void;
  /// A new chat's machine was picked where no folder of it is known: the chat starts there.
  onComputer?(computer: string): void;
  projectChoices?: Project[];
  /// A chat on another machine: that machine's own folders (`project.list`), for its folder menu.
  machineFolders?: Project[];
  onBrowseProject?(): void;
  /// New Worktree: a new chat on this Mac starts in a worktree of its folder (cx-lyqio.2).
  onNewWorktree?(cwd: string): void;
  /// A started chat's Choose folder…: the host's folder panel (see ComposerContext).
  onBrowseFolder?(): Promise<string | undefined>;
  /// The location row's SSH… and New Cloud Machine rows open the host's connect flows.
  onConnect?(kind: ConnectKind): void;
  /// A started chat's Move to Cloud or Bring Back Local (see ComposerContext), as `offloads` lists them.
  onOffload?(kind: OffloadKind): void;
  offloads?: readonly OffloadKind[];
  /// The environment picker opened: read the machines and their status again.
  onRefreshMachines?(): void;
  /// The folder menu's quiet line while a new chat has no folder (ComposerContext `folderNote`).
  folderNote?: string;
  /// A new chat's Run as rows in the environment picker (Persistent or Sandboxed, hq#3367).
  runMode?: RunModeRows;
  /// This Mac's name for the location row.
  localName?: string;
  /// Preview features on: the location row's computer is the environment picker (ComposerContext).
  environments?: boolean;
  /// A started chat's folder menu: a new chat in `cwd`, in a tab of its own.
  onNewChat?(cwd: string): void;
  /// A trust question takes precedence over an open destination picker.
  closeOnTrustAsk?: boolean;
  /// Shell mode (`!` first): runs `command` on the chat's machine in its folder, its block in the
  /// transcript; returns the run, which the next prompt carries as a removable chip. Unset, `!` is
  /// plain text.
  onShell?(command: string): ShellRun | undefined;
  /// Ctrl-C: stops the chat's newest running command; false when none runs.
  onShellInterrupt?(): boolean;
  /// The + menu's Plan/Build toggle (permission modes live in the access chip beside +).
  onMode?(modeId: string): void;
  /// ⌘Return, only where set (the Quick Composer): sends what was typed as Return would, then
  /// asks to open the chat in a window. `sent` says whether there was a prompt to send.
  onOpenInWindow?(sent: boolean): void;
  /// ⌘Return on an empty prompt while no turn runs (where it does nothing else): the recap card's
  /// yes (RecapCard.tsx). Set only while that card shows.
  onEmptyCommandReturn?(): void;
  /// Shell mode (`!` first) on or off: its ⌘Return answers no recap card, so the card drops its key.
  onShellChange?(shell: boolean): void;
  /// A concrete `reason` keeps the prompt while the folder's trust question is open. An empty
  /// object only means the trust read is in flight; the daemon still authorizes each send.
  blocked?: SendBlock;
  /// A new chat waiting on its folder choice: no prompt goes, including a trust-resend callback.
  /// Shell mode still runs. This is separate from a trust read's empty `blocked` object.
  blockSend?: boolean;
  /// A Cloud start is out: the box takes no input until it ends (ComposerBox `inert`), since this
  /// tab closes once the chat opens on the machine and an edit made meanwhile would be lost.
  locked?: boolean;
  /// Current session/route auth refusal. Unlike folder Trust, force-send cannot bypass it.
  authBlock?: string;
  /// Keeps auth refusal blocking sends when its text is represented by another notice.
  authBlocked?: boolean;
  /// Opens Session Info at its Context section: the context ring's card links to it (Details ›).
  onOpenContext?(): void;
};

/// The prompt box with the agent's `/` command menu:
/// the prompt over a bar with + at the left, the mode and model chips, and a
/// round Send button at the right, which turns into Stop while a turn runs and
/// the prompt is empty. Enter sends and
/// Shift+Enter breaks the line. The menu opens while the prompt is a single
/// leading `/word`, filters as it grows, and picking a command writes `/name `
/// so its arguments can follow.
export function Composer({
  snapshot,
  headerCwd,
  chips: Chips,
  onSend,
  onStop,
  onQueueRemove,
  onQueueCancelEdit,
  onQueueChange,
  onQueueLost,
  onQueueSideChat,
  queueImage,
  draft,
  chatKnown = true,
  leading,
  accessory,
  dictating = false,
  prompt,
  onEdit,
  onCmuxCommand,
  onUnsentDraft,
  onTyping,
  keptAttachments,
  onImportFile,
  importSandboxed,
  searchFiles,
  capture,
  plusExtensions,
  onPlusCommand,
  upload,
  localPaths,
  onProject,
  onComputer,
  projectChoices,
  machineFolders,
  onBrowseProject,
  onNewWorktree,
  onBrowseFolder,
  onConnect,
  onOffload,
  offloads,
  onRefreshMachines,
  folderNote,
  runMode,
  localName,
  environments,
  onNewChat,
  closeOnTrustAsk = false,
  onShell,
  onShellInterrupt,
  onMode,
  onOpenInWindow,
  onEmptyCommandReturn,
  onShellChange,
  handle,
  onUnplacedQuotes,
  sessionId,
  switching,
  blocked,
  blockSend = false,
  locked = false,
  authBlock,
  authBlocked = false,
  placeholder,
  onOpenContext,
}: Props) {
  const t = useT();
  const chrome = useComposerChrome();
  // Off (a queued row's ⋯ menu, queueing.ts), what is sent mid-turn steers on every key.
  const queueing = useQueueing();
  // A press outside an open chip menu only closes it (menuPressGuard.ts).
  useMenuPressGuard();
  // The native action map is replaced on reconnect while the session stays the same. Subscribe
  // so a durable read retries as soon as that map is available again.
  const draftActionsVersion = useDraftActionsVersion();
  const [findingFiles, setFindingFiles] = useState(false);
  // A new folder (another chat) closes the palette, so no row from the last one stays pickable.
  useEffect(() => setFindingFiles(false), [searchFiles]);
  // Search Files… (the app's command palette, cx-ncc.69) opens the same search the + menu does.
  useEffect(() => {
    if (!searchFiles) return;
    const open = () => setFindingFiles(true);
    window.addEventListener("cmux-acpmux-searchFiles", open);
    return () => window.removeEventListener("cmux-acpmux-searchFiles", open);
  }, [searchFiles]);
  // Search files sits over the transcript, so it mounts in the composer's parent (the pane's
  // main column), not inside the composer the slash menu anchors to.
  const form = useRef<HTMLFormElement>(null);
  const importInput = useRef<HTMLInputElement>(null);
  // Seed from the handshake before the editor mounts. The relaunch draft and the local cache can
  // arrive in the same render; preferring the host value keeps it visible through initialization.
  const [text, setText] = useState(() => draft ?? readPersistedDraft(sessionId) ?? "");
  const textRef = useRef(text);
  textRef.current = text;
  /// Shell mode: the prompt is a plain monospace field whose Enter runs a command. The markdown
  /// prompt stays mounted under it, keeping its own draft.
  const [shell, setShellState] = useState(false);
  const shellChange = useRef(onShellChange);
  shellChange.current = onShellChange;
  const setShell = (on: boolean) => {
    setShellState(on);
    shellChange.current?.(on);
  };
  const [shellText, setShellText] = useState("");
  const shellRef = useRef({ shell, shellText });
  shellRef.current = { shell, shellText };
  const shellField = useRef<HTMLTextAreaElement>(null);
  const shellCaret = useRef<number | undefined>(undefined);
  const [caret, setCaret] = useState(0);
  const [active, setActive] = useState(0);
  const [dismissed, setDismissed] = useState<string | undefined>();
  /// The `/word` the prompt's caret ends (MarkdownField `onSlash`), which opens the menu.
  const [slash, setSlash] = useState<SlashTrigger | undefined>();
  // The @ picker (MentionMenu.tsx): the row moved to, by its key, and the prompt text Esc closed it on.
  const [mentionActive, setMentionActive] = useState<string | undefined>();
  const [mentionDismissed, setMentionDismissed] = useState<string | undefined>();
  // The suggested prompt Esc put away: its chat and PR, so it stays away for this chat only.
  const [suggestionDismissed, setSuggestionDismissed] = useState<string | undefined>();
  // The handle is made once: its notices read the current locale's strings.
  const tRef = useRef(t);
  tRef.current = t;
  const field = useRef<MarkdownFieldHandle>(null);
  const fieldRef = useCallback(
    (handle: MarkdownFieldHandle | null) => {
      field.current = handle;
      if (prompt) prompt.current = handle;
    },
    [prompt],
  );
  // The editor can stay mounted while a turn streams. Keep the callbacks it calls stable so the
  // memoized Milkdown field does not reconcile for every inbound snapshot; the refs are refreshed
  // below after the current render has computed the live steer/queue behavior.
  const promptBeforeInput = useRef<NonNullable<MarkdownFieldProps["onBeforeInput"]>>(() => false);
  const promptChange = useRef<MarkdownFieldProps["onChange"]>(() => {});
  const promptCaret = useRef<NonNullable<MarkdownFieldProps["onCaret"]>>(() => {});
  const promptKeyDown = useRef<NonNullable<MarkdownFieldProps["onKeyDown"]>>(() => {});
  const promptReturnInput = useRef<NonNullable<MarkdownFieldProps["onReturnInput"]>>(() => {});
  const promptComposition = useRef<NonNullable<MarkdownFieldProps["onCompositionChange"]>>(() => {});
  const promptUnplacedQuotes = useRef(onUnplacedQuotes);
  promptUnplacedQuotes.current = onUnplacedQuotes;
  const stablePromptCallbacks = useMemo(
    () => ({
      onBeforeInput: (...args: Parameters<NonNullable<MarkdownFieldProps["onBeforeInput"]>>) =>
        promptBeforeInput.current(...args),
      onChange: (...args: Parameters<MarkdownFieldProps["onChange"]>) => promptChange.current(...args),
      onCaret: (at: number) => promptCaret.current(at),
      onKeyDown: (event: KeyboardEvent) => promptKeyDown.current(event),
      onReturnInput: () => promptReturnInput.current(),
      onCompositionChange: (value: boolean) => promptComposition.current(value),
      onUnplacedQuotes: (quotes: string[]) => promptUnplacedQuotes.current?.(quotes),
    }),
    [],
  );
  const pendingCaret = useRef<number | undefined>(undefined);
  /// When the person last pressed an editing key, input text or composed: a field change soon
  /// after is theirs (typing), any other is applied from outside.
  const typedAt = useRef(Number.NEGATIVE_INFINITY);
  /// A value applied from outside (a draft, another chat's prompt, a restore, a send's clear): the
  /// key before it, if it changed nothing itself, does not make the applied change typing.
  const notTyped = () => {
    typedAt.current = Number.NEGATIVE_INFINITY;
  };
  /// The person edited this chat's prompt before its durable draft read answered (a clear too):
  /// that read keeps their text, empty or not, and a quit before it answers saves it.
  const editedBeforeHydration = useRef(false);
  /// The text the durable read left in the prompt (acpmux's draft, or what the prompt already held):
  /// with nothing queued since, a quit compares the editor with it, so an untouched prompt never
  /// clears a draft another client (the CLI, another window) saved while this page was open.
  const hydratedText = useRef("");
  const prompts = usePromptHistory(snapshot.rows);
  // Send becomes Stop in place once the turn starts; a second click of a
  // double-click, or a click right after Enter, must not cancel the new turn.
  const sentAt = useRef(0);
  /// What + wrote over the draft, so Escape can put the draft back.
  const plusDraft = useRef<{ written: string; original: string } | undefined>(undefined);
  const composing = useRef(false);
  // Send and Stop are separate buttons, so focus on Send moves to whichever replaces it.
  const refocusSend = useRef(false);
  /** Stop had focus when pressed: it leaves with the turn, so the prompt takes focus back. */
  const refocusField = useRef(false);
  /// The session id owns the prompt. A page can switch sessions without remounting the composer.
  const persistedSession = useRef(sessionId);
  const hydratedSession = useRef<string | undefined>(undefined);
  const restoringSession = useRef(false);
  /// Set while a switch runs and kept until the session change it brings (Lucas 2026-10-19).
  const carryPrompt = useRef(false);
  /// A folder-trust recovery carries only its draft text. Keep source chips with that chat while
  /// destination selection is in flight, then release after the destination is rendered.
  const suppressedAttachmentCarry = useRef<{ from?: string } | undefined>(undefined);
  // Once a new chat has shown its location strip, keep its layout slot through the first send.
  // Resetting on a session key prevents a reopened chat from inheriting that reserved space.
  const locationSlotSession = useRef<string | undefined>(undefined);
  const locationSlotWasShown = useRef(false);
  const sendButton = useRef<HTMLButtonElement>(null);
  // Whether Esc stops a turn on a double press (escapeStop.ts).
  const { showContextUsage, spellChecking, escapeDoublePress, scrollToBottomOnSend, plainFooter } =
    useComposerSettings();
  // Both looks put the model in the footer and draw Claude's draft-sensitive Send and Stop slot
  // (composerLook.ts; Leo 2026-11-01: "we already have a good version").
  const look = useComposerLook();
  const quietActions = plainFooter;
  const usage = snapshot.summary?.usage;
  /// Set while the host has not yet taken a prompt the composer still holds: Enter sends no copy.
  const sending = useRef(false);
  /// The newest submit, for the handle's `send` (rendered after the trust answer lands).
  const submitNow = useRef<(force: boolean, steer?: boolean) => boolean>(() => false);
  /// The newest `onOpenInWindow`, for a ⌘Return held until a screenshot's chip is ready.
  const openInWindow = useRef(onOpenInWindow);
  openInWindow.current = onOpenInWindow;
  const allowImages = snapshot.summary?.promptCapabilities?.image !== false;
  // A paste on the prompt or the shell field, and a file drop anywhere (composer/attachmentIntake.tsx).
  // The composer's card, and the chat column around it that a file drag covers (composer/DropOverlay.tsx).
  const composerBox = useRef<HTMLDivElement | null>(null);
  const [dropHost, setDropHost] = useState<Element | null>(null);
  const setComposerBox = useCallback((element: HTMLDivElement | null) => {
    composerBox.current = element;
    setDropHost(element ? (element.closest(".acpmux-main") ?? element.ownerDocument.body) : null);
  }, []);
  const landingTarget = useCallback(() => composerBox.current, []);
  const {
    attachments,
    setAttachments,
    pending,
    loading,
    unsettled,
    videoReading,
    cancel,
    retry,
    revive,
    originalFailures,
    originalUploads,
    attachError,
    setAttachError,
    drop,
    dropLanded,
    attach,
    attachLater,
  } = useAttachmentIntake({
    place: (chips) => {
      if (!shell) box.current?.place(chips);
    },
    allowImages,
    dropZone: () => composerBox.current?.closest(".acpmux-main") ?? null,
    locked: () => locked,
    // A file pasted in shell mode is kept for the next prompt and uploads nothing; the mode stays.
    pasteTarget: (target) =>
      shellField.current?.contains(target)
        ? { uploads: false }
        : field.current?.element()?.contains(target)
          ? { uploads: true }
          : undefined,
    ...(upload ? { upload } : {}),
    ...(localPaths ? { localPaths } : {}),
    // A screenshot still being read when the composer moves to another chat stays the chat's it was
    // pasted in: its chip joins that chat's kept chips (keptAttachments.ts), unless a switch carries
    // the prompt to its new session.
    scope: sessionId,
    // A chat on this Mac (Quick Chat too): its attached videos show their posters.
    localChat: opensProcessTerminal(snapshot.summary),
    elsewhere: (chat, chips) => {
      if (keptAttachments) void keepElsewhere(keptAttachments, chat, chips);
    },
    carries: () => !suppressedAttachmentCarry.current && (carryPrompt.current || Boolean(switching)),
    suppressCarry: (from) => {
      const suppressed = suppressedAttachmentCarry.current;
      return Boolean(suppressed && suppressed.from === from);
    },
  });
  const attachmentsRef = useRef(attachments);
  attachmentsRef.current = attachments;
  const pendingRef = useRef(pending);
  pendingRef.current = pending;
  /// A new chat's text as the host keeps it (`onUnsentDraft`): the person's words only. The host keeps
  /// no attachment with it, so each attachment's token goes, a placeholder still being read included.
  /// A new chat's kept draft (the handshake's) that did not fit the limit beside text typed before it
  /// came (`draftFits`): the host keeps it, not the editor's text, until the editor is cleared, which
  /// brings it back into the editor. Before (cmux#28204 review at b7cddbbf), the merge past the limit
  /// went to the host, whose store turned it into nil and removed the kept draft.
  const keptOverLimit = useRef<string | undefined>(undefined);
  const unsentText = (value: string) =>
    keptOverLimit.current ??
    withoutInlineTokens(
      value,
      (id) =>
        attachmentsRef.current.some((chip) => chip.id === id) || pendingRef.current.some((chip) => chip.id === id),
    );
  // A prompt sent while a pasted screenshot is still being read goes once its chip is ready.
  const holdForAttachments = useSendWhenAttached(loading + videoReading, sessionId, unsettled + videoReading);
  /// A prompt too large for one acpmux message waits for its images' originals still uploading,
  /// then goes with them as links (promptBudget.ts); the person's x on one lets it go without it.
  const holdForOriginals = useSendWhenOriginals(
    attachments.filter((attachment) => originalUploads.has(attachment.id)).length,
    sessionId,
  );
  // The box makes a huge paste a chip; Paste as Plain Text keeps it raw (composer/pastedChips.ts).
  const box = useRef<ComposerBoxHandle>(null);
  // A paste anywhere in the pane outside a text field goes into the prompt, after what is already
  // there (composer/pasteAnywhere.ts).
  usePasteAnywhere(() => {
    // A Cloud start is out (`locked`): the prompt takes nothing until it ends.
    if (locked) return false;
    const shellInput = shellRef.current.shell ? shellField.current : null;
    if (shellInput) {
      shellInput.focus();
      shellInput.setSelectionRange(shellInput.value.length, shellInput.value.length);
      return true;
    }
    const prompt = field.current;
    if (!prompt?.element()) return false;
    prompt.focus();
    prompt.setCaret(Number.MAX_SAFE_INTEGER);
    return true;
  });
  // + then Attach files clicks this input: the system file chooser (an open panel in the app).
  const chooser = useRef<HTMLInputElement>(null);
  useLayoutEffect(() => {
    if (refocusField.current && !snapshot.isWorking) {
      refocusField.current = false;
      if (!document.activeElement || document.activeElement === document.body) field.current?.focus();
    }
    if (!refocusSend.current) return;
    const focused = document.activeElement;
    // The user moved on before the turn started: leave their focus alone.
    if (focused && focused !== document.body && focused !== sendButton.current) {
      refocusSend.current = false;
      return;
    }
    sendButton.current?.focus();
    if (snapshot.isWorking) refocusSend.current = false;
  });
  /// The one step every answered read of `sessionId`'s acpmux draft goes through (the load's read and
  /// a quit's, whichever answers first): it decides the prompt (hydratedDraft), puts it in the editor,
  /// records it as hydrated, writes it to acpmux if needed, and only then marks the draft read. A read
  /// that answers after another one did runs the same rule on what the editor now holds, so it never
  /// writes a pre-merge prompt over the merge. Before (cmux#28204 review at ffdbd9d1), a quit's read
  /// saved "saved\n\ntyped" and marked the draft read while the editor still held "typed"; the load's
  /// read then kept "typed" and wrote it over the merged draft.
  const applyDraftRead = (session: string | undefined, saved: string | undefined): string => {
    const currentText = field.current?.value() ?? textRef.current;
    const history = draftHistory(session);
    const edited = editedBeforeHydration.current || history.edited;
    editedBeforeHydration.current = false;
    const next = hydratedDraft({ current: currentText, restored: saved, ...history, edited });
    if (next.overflow) {
      // acpmux's draft and the typed text do not fit the limit together: acpmux keeps its draft,
      // the editor keeps the typing, and the chat stays unread, so no edit or quit writes the typed
      // text over the saved draft; the next read tries again (deleting the typing brings it back).
      editedBeforeHydration.current = true;
      noteDraftKeptApart(session);
      if (session) cachePersistedDraft(session, currentText);
      return currentText;
    }
    if (next.shown) {
      // Its own write (below) or none: the text effect does not write it again.
      restoringSession.current = next.text !== textRef.current;
      notTyped();
      // The editor at once, not on the next render: a quit about to unmount reads it, and a read
      // that answers before the render must see the merged prompt.
      if (field.current && field.current.value() !== next.text) field.current.reset(next.text);
      textRef.current = next.text;
      setText(next.text);
      setCaret(next.text.length);
      pendingCaret.current = next.text.length;
    }
    hydratedText.current = next.text;
    // A local remount cache or keystroke arrived before the daemon read: preserve it durably.
    if (next.write) writePersistedDraft(session, next.text);
    else if (session && next.text === (saved ?? "")) noteDraftHeld(session, next.text);
    // After the write: a chat with nothing on its way to acpmux is settled (edits and sends
    // forgotten); one with a write out stays the page's until a later read finds it answered.
    markDraftRead(session);
    hydratedSession.current = session;
    flushPendingDraftWrites();
    return next.text;
  };
  useImperativeHandle(
    handle,
    () => ({
      draft() {
        return {
          text: field.current?.value() ?? textRef.current,
          attachments: attachmentsRef.current.filter((attachment) => !attachment.shellRun),
        };
      },
      draftText: () =>
        withoutInlineTokens(field.current?.value() ?? textRef.current, (id) =>
          attachmentsRef.current.some((attachment) => attachment.id === id),
        ),
      suppressAttachmentCarryFor(sessionId) {
        suppressedAttachmentCarry.current = { from: sessionId };
      },
      clearAttachmentCarrySuppression() {
        suppressedAttachmentCarry.current = undefined;
      },
      restore(restoredText, restoredAttachments) {
        // A prompt coming back (refused, taken back, edited from the queue) went with a Codex skill
        // as `/$name`: it is typed `/name` here, and send writes the `$` again.
        const restored = bindMarks(withoutSkillDollars(restoredText), restoredAttachments);
        restoredText = restored.text;
        restoredAttachments = restored.attachments;
        // The editor parses tokens synchronously; make their payload IDs known before replacing its document.
        attachmentsRef.current = appendAttachments(attachmentsRef.current, restoredAttachments);
        // Put back, not typed: the Enter that sent it says nothing about this change.
        notTyped();
        // What comes back goes first; what was typed or attached since stays after it.
        const typed = field.current?.value() ?? "";
        const next = typed.trim() ? `${restoredText}\n\n${typed}` : restoredText;
        // A field whose editor is still starting (the chat composer that mounts as a New Tab page
        // leaves) takes it as its value, which becomes the editor's first content.
        if (!field.current?.type(next)) {
          setText(next);
          setCaret(next.length);
        }
        if (restoredAttachments.length)
          setAttachments((current) => [
            ...restoredAttachments,
            ...current.filter((attachment) => !restoredAttachments.some((back) => back.id === attachment.id)),
          ]);
      },
      attach(attachment) {
        // A pick past the most the composer holds says so, as a dropped file does.
        const held = attachmentsRef.current;
        const next = appendAttachments(held, [attachment]);
        // Ahead of the render, so each of several picks attached at once counts the ones before it.
        attachmentsRef.current = next;
        setAttachments((current) => {
          const next = appendAttachments(current, [attachment]);
          return next;
        });
      },
      attachLater,
      detach(ids) {
        setAttachments((current) => current.filter((chip) => !ids.includes(chip.id)));
        // Their places in the text go with them: no empty atom stays in the draft.
        for (const id of ids) field.current?.removeInline(id);
      },
      send: () => submitNow.current(true),
      focus: () => field.current?.focus(),
      prefill(prefix) {
        const typed = (field.current?.value() ?? textRef.current).trimStart();
        if (!typed.startsWith(prefix.trimEnd())) {
          const next = prefix + typed;
          pendingCaret.current = next.length;
          setText(next);
          setCaret(next.length);
        }
        field.current?.focus();
      },
      quoteReply(markdown) {
        notTyped();
        if (!field.current?.quoteReply(markdown)) {
          const typed = textRef.current;
          const next = typed ? typed + "\n\n" + markdown : markdown;
          textRef.current = next;
          pendingCaret.current = next.length;
          setText(next);
          setCaret(next.length);
          field.current?.focus();
        }
      },
      wakeState: () => ({
        attachments: attachmentsRef.current.filter((chip) => !chip.shellRun),
        shell: shellRef.current.shell,
        shellText: shellRef.current.shellText,
      }),
      async settleDraft() {
        // The editor's value, not React's state: a keystroke whose effects have not run yet counts.
        let typed = field.current?.value() ?? textRef.current;
        const session = persistedSession.current;
        // Typed while the chat loaded, and acpmux's draft never read: read it now, so the quit
        // keeps both instead of writing the typed text over it (mergedDraft). No answer: as before.
        let readAnswered = !session || draftWasRead(session);
        if (session && hydratedSession.current !== session && editedBeforeHydration.current && !readAnswered) {
          const saved = await readDurableDraftState(session);
          if (!saved) {
            // A failed read is not an empty draft. Keep the latest text in the remount cache and
            // wait for a successful read before sending anything to acpmux, so reconnect cannot
            // replace a durable draft with the text typed during the outage.
            cachePersistedDraft(session, field.current?.value() ?? textRef.current);
            const unsent = unsentDraft.current;
            if (unsent) unsent.push(unsentText(field.current?.value() ?? textRef.current));
            await Promise.all([unsent?.settle(), settlePendingDraftWrites()]);
            return;
          }
          // The composer moved to another chat while acpmux answered: the typed text stays in the
          // remount cache (above, the text effect), and that chat's own read merges it.
          if (persistedSession.current !== session) {
            await Promise.all([unsentDraft.current?.settle(), settlePendingDraftWrites()]);
            return;
          }
          // Re-read after the async call: the person may have typed while acpmux was answering. The
          // read on open's own step (applyDraftRead): the merge goes into the editor and is written
          // before the draft counts as read, so the load's read, answering later, keeps it.
          typed = applyDraftRead(session, saved.draft);
          // Unread still when the merge did not fit (applyDraftRead): the typing is not written.
          readAnswered = draftWasRead(session);
        }
        // A restore not yet committed (`restoringSession`) is acpmux's own draft: the editor still
        // shows what it had before, so writing it would clear the draft being restored.
        // Before the durable read answers, only what the person typed goes (the read keeps a typed
        // prompt over acpmux's the same way); an untouched editor leaves acpmux's draft alone.
        const ready = hydratedSession.current === session || (editedBeforeHydration.current && readAnswered);
        const known =
          lastQueuedDraftText(session ?? "") ??
          (hydratedSession.current === session ? hydratedText.current : undefined);
        if (session && ready && !restoringSession.current && typed !== known) {
          writePersistedDraft(session, typed);
        }
        const unsent = unsentDraft.current;
        if (unsent) unsent.push(unsentText(typed));
        await Promise.all([unsent?.settle(), settlePendingDraftWrites()]);
      },
      wake(state) {
        const back = state.attachments ?? [];
        if (back.length)
          setAttachments((current) => [
            ...back,
            ...current.filter((chip) => !back.some((kept) => kept.id === chip.id)),
          ]);
        if (state.shell) {
          setShell(true);
          setShellText(state.shellText ?? "");
          shellCaret.current = state.shellText?.length ?? 0;
        }
      },
    }),
    [setAttachments, attachLater],
  );
  useEffect(() => {
    if (!draft) return;
    // The prompt's DOM value is the typed text; a draft never replaces it. A draft that arrives
    // after the person started typing (the handshake slower than their keys) goes before what
    // they typed, so neither is lost (mergedDraft); before, it was dropped, and the typed text
    // then replaced the tab's kept draft on disk.
    const typed = field.current?.value() ?? textRef.current;
    // Merged only before the page read this chat's draft; after it, the prompt is the draft.
    if (draftWasRead(persistedSession.current)) return;
    const next = mergedDraft(typed, draft);
    if (next === typed) return;
    if (!draftFits(next)) {
      // Both do not fit the limit: the host keeps the kept draft and the editor the typing.
      keptOverLimit.current = draft;
      unsentDraft.current?.push(draft);
      return;
    }
    keptOverLimit.current = undefined;
    notTyped();
    field.current?.reset(next);
    setText(next);
    setCaret(next.length);
    pendingCaret.current = next.length;
  }, [draft]);
  useEffect(() => {
    if (switching) carryPrompt.current = true;
  }, [switching]);
  useEffect(() => {
    if (persistedSession.current === sessionId) return;
    // A switch's new session has no draft yet: the prompt typed before the pick moves to it.
    const carried = carryPrompt.current ? (field.current?.value() ?? text) : "";
    const previous = persistedSession.current;
    // The composer had no chat yet (the page still loading or reconnecting, a new chat whose
    // session just started): what it holds was typed for this chat. It stays, merged with the
    // chat's saved draft. Before, this reset the prompt to the saved draft or to empty, so text
    // typed before the chat loaded was cleared.
    const typedBefore = previous === undefined && !carryPrompt.current ? (field.current?.value() ?? text) : "";
    if (previous && hydratedSession.current === previous) writePersistedDraft(previous, field.current?.value() ?? text);
    // This composer leaves that chat: only a quit compares its queued text, and only for the chat shown.
    forgetQueuedDraft(previous);
    persistedSession.current = sessionId;
    // Another chat's prompt comes in: no key before it was typing for this one.
    notTyped();
    hydratedSession.current = undefined;
    editedBeforeHydration.current = false;
    restoringSession.current = true;
    const restored = readPersistedDraft(sessionId) ?? "";
    // A relaunch draft arrives with the handshake at the same time as the session reset. Keep it
    // when the local remount cache is empty; otherwise this effect can clear the host-provided
    // draft before the editor has initialized.
    // A chat's own saved draft wins: carried text only fills a session that has none, which a
    // switch's new session always is, so moving to another chat mid-switch keeps that chat's draft.
    // Merged only before the page ever read this chat's draft; after it, what was typed wins.
    const initial = typedBefore.trim()
      ? draftWasRead(sessionId) || !draftFits(mergedDraft(typedBefore, restored || draft))
        ? typedBefore
        : mergedDraft(typedBefore, restored || draft)
      : restored || carried || draft || "";
    // Not yet acpmux's: the durable read merges it with acpmux's draft and writes the result.
    if (typedBefore.trim()) {
      editedBeforeHydration.current = true;
      noteDraftEdited(sessionId);
      if (sessionId) cachePersistedDraft(sessionId, initial);
    }
    setText(initial);
    setCaret(initial.length);
    pendingCaret.current = initial.length;
  }, [sessionId, text, draft]);
  // The pane closes: what it queued for its chat still goes to acpmux, but no quit compares it again.
  useEffect(() => () => forgetQueuedDraft(persistedSession.current), []);
  // The chat's own chips come back with its prompt; a switch carries the ones held (keptAttachments.ts).
  useKeptAttachments(
    sessionId,
    attachments,
    setAttachments,
    keptAttachments,
    () => !suppressedAttachmentCarry.current && carryPrompt.current,
  );
  // Run after useKeptAttachments' session read/effects. Recovery copied text only; ordinary
  // switching can carry attachments again once the destination session is shown.
  useEffect(() => {
    const suppressed = suppressedAttachmentCarry.current;
    if (suppressed && sessionId !== suppressed.from) suppressedAttachmentCarry.current = undefined;
  }, [sessionId]);
  // WEB-SWAP: a web update reloads the page only when the prompt comes back as it is: text and
  // chips kept with the chat (composerDraft.ts, keptAttachments.ts), nothing being sent, read or
  // dictated, no shell mode (pages/shared/webSwap.ts).
  const swapState = useRef({ dictating, reading: 0, sessionId, chips: 0 });
  swapState.current = { dictating, reading: pending.length, sessionId, chips: attachments.length };
  useEffect(
    () =>
      holdWebSwap(() => {
        const state = swapState.current;
        if (sending.current) return "composer.sending";
        if (state.dictating) return "composer.dictation";
        if (state.reading) return "composer.attachment-reading";
        if (shellRef.current.shell) return "composer.shell";
        // A new chat's prompt has no chat to keep it with yet.
        if (!state.sessionId)
          return (field.current?.value() ?? textRef.current).trim() || state.chips ? "composer.new-chat" : null;
        if (hydratedSession.current !== state.sessionId) return "composer.draft-restoring";
        return null;
      }),
    [],
  );
  // After the session effect, so a switch that ends with its session change still carries.
  useEffect(() => {
    if (!switching) carryPrompt.current = false;
  }, [switching]);
  useEffect(() => {
    let current = true;
    void readDurableDraftState(sessionId).then((state) => {
      if (!current) return;
      // acpmux did not answer (its action map not installed yet, a connection that failed or
      // dropped): nothing is known of its draft, so the chat is not hydrated. What the person types
      // meanwhile stays in the remount cache and goes to acpmux only once a read answered and
      // merged it (the action map's next version runs this again). Before, an unanswered read
      // counted as "no draft", and the typed text then replaced the draft acpmux kept.
      if (sessionId && !state) return;
      applyDraftRead(sessionId, state?.draft);
      // A web update reloaded the page while the prompt had the keyboard: it takes it back, the
      // caret after the text as it was (pages/shared/webSwap.ts).
      if (takeWebSwapFocus("composer"))
        requestAnimationFrame(() => {
          field.current?.focus();
          field.current?.setCaret(Number.MAX_SAFE_INTEGER);
        });
    });
    return () => {
      current = false;
    };
  }, [sessionId, draftActionsVersion]);
  useEffect(() => {
    if (restoringSession.current) {
      restoringSession.current = false;
      return;
    }
    if (hydratedSession.current !== sessionId) {
      // Typed before the chat's draft was read: kept for a remount (the composer swapped out while
      // the chat loads or reconnects), and merged by the read before it goes to acpmux.
      if (editedBeforeHydration.current) cachePersistedDraft(sessionId, text);
      return;
    }
    writePersistedDraft(sessionId, text);
  }, [sessionId, text]);
  // A new chat's text goes to the host at most every 300 ms while typing, and at once when the page is
  // hidden, the prompt loses focus or the prompt is sent (unsentDraftThrottle.ts).
  const unsentDraft = useRef<UnsentDraftThrottle | undefined>(undefined);
  useEffect(() => {
    if (sessionId || !onUnsentDraft) return;
    const throttle = createUnsentDraftThrottle({
      send: onUnsentDraft,
      intervalMs: UNSENT_DRAFT_INTERVAL_MS,
    });
    unsentDraft.current = throttle;
    const flush = () => throttle.flush();
    const hidden = () => {
      if (document.visibilityState === "hidden") throttle.flush();
    };
    window.addEventListener("pagehide", flush);
    document.addEventListener("visibilitychange", hidden);
    return () => {
      window.removeEventListener("pagehide", flush);
      document.removeEventListener("visibilitychange", hidden);
      throttle.flush();
      throttle.dispose();
      if (unsentDraft.current === throttle) unsentDraft.current = undefined;
    };
  }, [sessionId, onUnsentDraft]);
  useEffect(() => {
    const kept = keptOverLimit.current;
    if (kept !== undefined && !text.trim()) {
      // The typing is gone (deleted, or sent): the kept draft comes back into the editor.
      keptOverLimit.current = undefined;
      notTyped();
      field.current?.reset(kept);
      setText(kept);
      setCaret(kept.length);
      pendingCaret.current = kept.length;
      return;
    }
    unsentDraft.current?.push(unsentText(text));
  }, [text, sessionId, onUnsentDraft]);
  const commands = snapshot.commands;
  const remote = remoteComposer(snapshot);
  // Permission modes live in the access chip beside +; the + menu keeps only the Plan/Build toggle.
  const permissionModes = (snapshot.summary?.modes?.availableModes ?? []).filter(
    (mode) => !/(^|[-_])plan$/i.test(mode.id),
  );
  const plan = snapshot.summary?.modes?.availableModes?.find((mode) => /(^|[-_])plan$/i.test(mode.id));
  const currentModeId = snapshot.summary?.modes?.currentModeId;
  const lastMode = useRef<{ sessionId?: string; mode?: string }>({});
  if (lastMode.current.sessionId !== snapshot.summary?.sessionId) {
    lastMode.current = { sessionId: snapshot.summary?.sessionId };
  }
  if (currentModeId && !/(^|[-_])plan$/i.test(currentModeId)) lastMode.current.mode = currentModeId;
  const planning = plan?.id === currentModeId;
  /// Plan/Build: leaving Plan returns to the mode this session had before it.
  const togglePlan = (planId: string) =>
    onMode?.(planning ? (lastMode.current.mode ?? permissionModes[0]?.id ?? planId) : planId);
  const planChoice: Choice | undefined =
    plan && onMode
      ? {
          id: `plan:${plan.id}`,
          name: planning ? t("picker.build") : t("picker.plan"),
          icon: planning ? <BuildIcon /> : <PlanIcon />,
        }
      : undefined;
  // A prompt ↑ brought back keeps its arrows for history: a / command or @ mention in it opens no menu.
  const recalling = prompts.showing(() => field.current?.agentText(text) ?? text);
  // A `/word` at the prompt's start lists every command; one after a space or line break further
  // on lists those the agent reads anywhere (slashCommands.ts slashMatches), and opens only on a
  // match: mid-prompt, `/tmp` with nothing to offer is the person's text, not an empty menu.
  const typedSlash = slash !== undefined && dismissed !== text && !recalling ? slash : undefined;
  const query = typedSlash?.query;
  const matches = useMemo(() => (typedSlash ? slashMatches(commands ?? [], typedSlash) : []), [commands, typedSlash]);
  const open = typedSlash !== undefined && (typedSlash.leading || matches.length > 0);
  const slashNames = useSlashNames(commands);

  useEffect(() => setActive(0), [query]);
  // Typing @ at a word start lists other chats, then the chat's folders and files that match what
  // follows (cx-ncc.68, mentionItems.ts).
  const chatId = snapshot.summary?.sessionId;
  const otherChats = useMemo(() => hasOtherChats(snapshot.sessions, chatId), [snapshot.sessions, chatId]);
  const mentionTyped =
    !open && !recalling && (searchFiles || otherChats) && mentionDismissed !== text
      ? mentionQuery(text, markdownOffset(text, caret))
      : undefined;
  const mentionWord = mentionTyped?.query;
  const mentionSearch = useMentionSearch(searchFiles, mentionWord);
  const mentionFiles = mentionResults(mentionSearch);
  // Recent @ picks belong to this chat's folder on its machine, and only where its files are searched.
  const recentScope = searchFiles
    ? recentMentionScope(snapshot.summary?.cwd, snapshot.summary?.peer ?? snapshot.summary?.host)
    : undefined;
  const mentions = useMemo(
    () =>
      mentionWord === undefined
        ? []
        : mentionItems({
            query: mentionWord,
            files: mentionFiles,
            recent: loadRecentMentionPaths(recentScope),
            sessions: snapshot.sessions,
            chatId,
          }),
    [mentionWord, mentionFiles, snapshot.sessions, chatId, recentScope],
  );
  // A chat whose folder cannot be searched (a remote chat) opens the picker only on a matching
  // chat; it never hints at a file search.
  const mentionAt = searchFiles || mentions.length > 0 ? mentionTyped : undefined;
  // The word's files are still on their way: asked, or about to be once typing settles.
  const mentionPending =
    !!searchFiles && !!mentionWord?.trim() && (mentionSearch.kind === "idle" || mentionSearch.kind === "searching");
  const mentionSelected = mentionSelection(mentions, mentionActive, mentionPending);
  useEffect(() => setMentionActive(undefined), [mentionWord]);
  // A live command update can shrink the list under the selection.
  const selected = Math.min(active, Math.max(matches.length - 1, 0));
  useLayoutEffect(() => {
    const node = shellField.current;
    if (!node) return;
    // One line grows with what is typed, as the prompt does (no scrollbar under 40vh).
    node.style.height = "0px";
    node.style.height = `${node.scrollHeight}px`;
    if (shellCaret.current === undefined) return;
    node.focus();
    node.setSelectionRange(shellCaret.current, shellCaret.current);
    shellCaret.current = undefined;
  });
  useLayoutEffect(() => {
    if (pendingCaret.current === undefined || !field.current) return;
    field.current.setCaret(pendingCaret.current);
    pendingCaret.current = undefined;
  });

  const edit = (value: string, at: number) => {
    setText(value);
    setCaret(at);
    setDismissed(undefined);
    // Emptied (a command run, a prompt sent, the text deleted): this pane no longer types.
    if (!value.trim() && sessionId) onTyping?.("", sessionId);
  };
  // The commands picked last (any chat), for the + menu's few recent rows; read again as + opens.
  const [recentCommandNames, setRecentCommandNames] = useState(loadRecentCommandNames);
  const pick = (command: SlashCommand) => {
    setRecentCommandNames(rememberRecentCommand(command.name));
    // In place, over the typed `/word`, the text around it kept; the field reports the edit.
    if (field.current?.insertCommand(shownName(command))) {
      field.current.focus();
      return;
    }
    const next = applyCommand(text, caret, command);
    pendingCaret.current = next.caret;
    edit(next.text, next.caret);
    field.current?.focus();
  };
  const pickFromPlus = (command: SlashCommand) => {
    setRecentCommandNames(rememberRecentCommand(command.name));
    const existing = field.current?.value() ?? text;
    const next = `/${shownName(command)} ${existing}`;
    pendingCaret.current = next.length;
    edit(next, next.length);
    field.current?.focus();
  };
  /// The draft without what + wrote over it, while the text is still exactly that.
  const unwrapped = () => {
    const plus = plusDraft.current;
    return plus && plus.written === text ? plus.original : text;
  };
  /// An attachment's id, staged or still being read: its token in the text is a place, not words.
  const attachmentId = (id: string) =>
    attachmentsRef.current.some((chip) => chip.id === id) || pendingRef.current.some((chip) => chip.id === id);
  /// The person's words: the draft without its attachments' places, for reading a command from.
  const typedWords = () => withoutInlineTokens(unwrapped(), attachmentId);
  /// Writes the picked chat, folder or file over the `@word` being typed.
  const pickMention = (item: MentionItem) => {
    if (!mentionAt) return;
    rememberMentionPath(recentScope, item);
    const { markdown, shown } = mentionInsert(item);
    // Markdown doesn't show trailing whitespace, so what follows an end-of-prompt caret is dropped.
    const after = text.slice(markdownOffset(text, caret)).replace(/^\s+$/, "");
    const at = caret - 1 - mentionAt.query.length + shown.length;
    pendingCaret.current = at;
    edit(text.slice(0, mentionAt.start) + markdown + after, at);
    field.current?.focus();
  };
  /// Sends the draft; false when there was nothing to send or the host refused it.
  const submit = (event: { preventDefault(): void }): boolean => {
    event.preventDefault();
    // Send does what Return does: mid-turn it steers an agent that steers, else it queues.
    return send(false, steersAlways || returnSteers);
  };
  const send = (force: boolean, steer = false): boolean => {
    // A send waiting for its images' originals is this one's to replace: whatever this one does
    // (it goes, waits again, runs a command or stops), the earlier one never goes on its own.
    holdForOriginals(false, () => undefined);
    // acpmux refuses this chat on this connection (remoteEditing.ts): keep the draft.
    if (!remote.canSend) return false;
    // The folder's trust question is open: the prompt stays where it is.
    if (authBlock || authBlocked || blockSend || (blocked?.reason && !force)) return false;
    // The host has not taken the last prompt yet: it is still here, so Enter sends no copy, and
    // the composer says so instead of doing nothing.
    if (sending.current) {
      setAttachError(t("composer.stillSending"));
      return false;
    }
    // The field holds markdown with its typed text escaped; the agent gets the text as typed.
    const draftText = unwrapped();
    // The attachments placed in the text go at their places (attachments.ts placeInline); a chip still
    // being read is not one of them yet.
    // A Codex skill typed or picked as `/name` goes as `/$name` (slashCommands.ts withSkillDollars).
    const typedText = withSkillDollars(field.current?.agentText(draftText) ?? draftText, commands);
    const inText = placeInline(typedText.trim(), attachments, {
      dropped: (id) => pending.some((chip) => chip.id === id),
    });
    // A slash command reads from the words' start, wherever the attachments sit: it goes first and
    // its attachments after it, as from the strip, so the command and the host both still see it.
    // Only a command: cmux's own or a terminal-only spelling (counted as it reads with no
    // attachments), or one the agent offers by name. Other text that starts with "/" (a path) is an
    // ordinary prompt and keeps its attachments where they were put.
    const words = withoutInlineTokens(inText.text, attachmentId).trim();
    const slash = /^\/(\S+)/.exec(words)?.[1];
    const isCommand =
      slash !== undefined &&
      (composerCommand(words, snapshot.summary?.harness) !== undefined ||
        (commands ?? []).some((command) => command.name === slash));
    const placed = isCommand
      ? { text: words, attachments: attachments.map(({ inline: _, ...attachment }) => attachment) }
      : inText;
    const prompt = placed.text;
    const command = composerCommand(prompt, snapshot.summary?.harness, attachments.length);
    let owned = command?.kind === "cmux" ? command.command : undefined;
    const ownedArgs = command?.kind === "cmux" ? command.args : undefined;
    // A bare `/plan` is the + menu's Plan/Build toggle: leaving Plan returns to the remembered mode.
    if (owned?.action === "plan" && !ownedArgs?.trim() && plan && onMode) {
      togglePlan(plan.id);
      setAttachError(undefined);
      plusDraft.current = undefined;
      edit("", 0);
      sentAt.current = Date.now();
      return true;
    }
    if (owned) {
      // Side questions carry text only; staged files stay here for the main turn.
      // A file still being read counts too: /btw must not cancel it.
      if (owned.action === "btw" && (attachments.length > 0 || pending.length > 0)) return false;
      if (owned.name === "import") {
        if (importSandboxed) {
          setAttachError(t("composer.cmuxImportSandbox"));
          return false;
        }
        if (!onImportFile) {
          setAttachError(t("composer.cmuxUnavailable"));
          return false;
        }
        importInput.current?.click();
      } else if (!onCmuxCommand) {
        if (!harnessTakesToo(owned)) {
          setAttachError(t("composer.cmuxUnavailable"));
          return false;
        }
        owned = undefined;
      } else {
        const accepted = onCmuxCommand(owned, ownedArgs);
        // A passthrough command goes as a normal prompt, keeping its staged attachments.
        if (accepted === CMUX_PASS_THROUGH) owned = undefined;
        else if (typeof accepted === "string") {
          setAttachError(accepted);
          return false;
        }
        if (accepted === false) {
          setAttachError(t("composer.cmuxUnavailable"));
          return false;
        }
        if (accepted instanceof Promise) {
          // The draft as the command took it, without the places of the reads it cancels: their
          // nodes leave the text after this (inlineAttachments.tsx), which is no edit of the person's.
          const dropped = new Set(pending.map((item) => item.id));
          const asTaken = (value: string) => withoutInlineTokens(value, (id) => dropped.has(id));
          const written = asTaken(field.current?.value() ?? "");
          holdForAttachments.cancel();
          // Accepted commands consume staged files before their async work starts. A pending read
          // must not leak into the next prompt while the command waits.
          for (const item of pending) cancel(item.id);
          const went = new Set(attachments.map((attachment) => attachment.id));
          box.current?.sent(went);
          setAttachments((current) => current.filter((attachment) => !went.has(attachment.id)));
          setAttachError(undefined);
          plusDraft.current = undefined;
          sending.current = true;
          accepted.then(
            () => {
              sending.current = false;
              if (asTaken(field.current?.value() ?? "") === written) edit("", 0);
              sentAt.current = Date.now();
            },
            (reason: unknown) => {
              sending.current = false;
              // A command may refuse with its own sentence (`/cd` to a path that is no folder).
              setAttachError(reason instanceof CmuxCommandRefused ? reason.message : t("composer.cmuxUnavailable"));
            },
          );
          return true;
        }
      }
      // A passthrough command falls through to the normal send path below.
      if (owned) {
        // Accepted commands consume staged files, including reads still pending when /import opened.
        holdForAttachments.cancel();
        for (const item of pending) cancel(item.id);
        // By id: a chip patched after it went (its original's path arriving) is still the one sent.
        const went = new Set(attachments.map((attachment) => attachment.id));
        box.current?.sent(went);
        setAttachments((current) => current.filter((attachment) => !went.has(attachment.id)));
        setAttachError(undefined);
        plusDraft.current = undefined;
        edit("", 0);
        sentAt.current = Date.now();
        return true;
      }
    }
    // A file pasted or dropped is still being read or uploaded: the prompt waits for its chip.
    if (holdForAttachments(() => submitNow.current(force, steer))) return false;
    // Too large for one message until the originals still uploading are saved: it waits for them.
    if (
      holdForOriginals(
        awaitsOriginals(prompt, placed.attachments, (id) => originalUploads.has(id)),
        () => submitNow.current(force, steer),
      )
    )
      return false;
    if (command?.kind === "cliOnly") {
      setAttachError(t(command.key, { command: command.name }));
      return false;
    }
    if (!prompt.trim() && placed.attachments.length === 0) {
      plusDraft.current = undefined;
      return false;
    }
    const fromSend = document.activeElement?.classList.contains("acpmux-send") ?? false;
    // The key that sent it is spent: what the composer writes back after the send is not typing.
    notTyped();
    unsentDraft.current?.flush();
    const sent = placed.attachments;
    const taken = onSend(placed.text, sent, steer);
    if (taken === false) return false;
    const written = field.current?.value() ?? "";
    const clear = (rest = "") => {
      const went = new Set(sent.map((attachment) => attachment.id));
      box.current?.sent(went);
      setAttachments((current) => current.filter((attachment) => !went.has(attachment.id)));
      setAttachError(undefined);
      plusDraft.current = undefined;
      if (field.current && rest) field.current.type(rest);
      else edit(rest, rest.length);
      // The sent text is no draft any more: a read still on its way never brings it back.
      noteDraftSent(persistedSession.current);
      sentAt.current = Date.now();
      refocusSend.current = fromSend;
    };
    if (!(taken instanceof Promise)) {
      clear();
      return true;
    }
    // The prompt stays in the composer until the host takes it; a refusal keeps it there.
    sending.current = true;
    taken.then(
      () => {
        sending.current = false;
        // What was typed while the host took the prompt stays.
        const now = field.current?.value() ?? written;
        clear(now === written ? "" : now.startsWith(written) ? now.slice(written.length).trimStart() : now);
      },
      () => {
        sending.current = false;
        const note = t("composer.stillSending");
        setAttachError((current) => (current === note ? undefined : current));
      },
    );
    return true;
  };
  submitNow.current = send;
  /// + then Mention: an "@" at the caret, set off by a space, for the agent to read as a path.
  // Writes "@" at the caret, or "@path " for a file picked in Search files.
  const mention = (path?: string) => {
    if (composing.current) return;
    const at = markdownOffset(text, caret);
    const before = text.slice(0, at);
    // A path with a space is quoted, or an agent would read the mention only up to it. The prompt
    // is markdown, which takes backslash escapes as its own, so a quote in a name is left as is.
    const mentioned = path && /\s/.test(path) ? `"${path}"` : path;
    const spaced = !before || /(\s|&#x20;|&#32;|&nbsp;)$/i.test(before);
    const shown = (spaced ? "@" : " @") + (mentioned ? `${mentioned} ` : "");
    // Escaped, the path reads as typed text (`__init__.py` is not bold); the caret counts what shows.
    const insert = shown.replace(/[\\`*_[\]~<]/g, "\\$&");
    plusDraft.current = undefined;
    pendingCaret.current = caret + shown.length;
    // Markdown doesn't show trailing whitespace, so what follows an end-of-prompt caret is dropped.
    const after = text.slice(at).replace(/^\s+$/, "");
    edit(before + insert + after, caret + shown.length);
    field.current?.focus();
  };
  // + then Commands opens the agent's commands: the menu reads the
  // text before the caret, so "/" ahead of the draft opens it and a pick keeps
  // the draft as arguments. A draft that already starts a command keeps its "/",
  // so a pick replaces that command; anything else (a pasted path) is kept whole.
  const openCommands = () => {
    if (composing.current) return;
    const first = /^\/(\S*)/.exec(text)?.[1];
    const named = first !== undefined && (commands ?? []).some((command) => command.name.startsWith(first));
    const next = named ? text : text ? `/ ${text}` : "/";
    plusDraft.current = { written: next, original: text };
    pendingCaret.current = 1;
    edit(next, 1);
    field.current?.focus();
  };
  const enterShell = (typed: string) => {
    setShell(true);
    setShellText(typed);
    shellCaret.current = typed.length;
  };
  /// Leaves shell mode; what was typed moves to the prompt, never lost.
  const exitShell = () => {
    const typed = shellText;
    setShell(false);
    setShellText("");
    field.current?.focus();
    if (typed) field.current?.writeText(typed, typed.length, typed.length);
  };
  const runShell = () => {
    const command = shellText.trim();
    if (!command || !onShell) return;
    const run = onShell(command);
    if (!run) return;
    setAttachments((current) => cappedShellChips([...current, shellAttachment(run)]));
    setShell(false);
    setShellText("");
    field.current?.focus();
  };
  const interrupt = (event: KeyboardEvent | React.KeyboardEvent) => {
    if (event.key !== "c" || !event.ctrlKey || event.metaKey || event.altKey || event.shiftKey) return false;
    if (!onShellInterrupt?.()) return false;
    event.preventDefault();
    return true;
  };
  const shellKeyDown = (event: React.KeyboardEvent<HTMLTextAreaElement>) => {
    if (event.nativeEvent.isComposing || event.keyCode === 229) return;
    if (interrupt(event)) return;
    const plain = !event.shiftKey && !event.altKey && !event.metaKey && !event.ctrlKey;
    if (event.key === "Enter" && plain) {
      event.preventDefault();
      runShell();
    } else if (event.key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      exitShell();
    } else if (
      event.key === "Backspace" &&
      shellText === "" &&
      event.currentTarget.selectionStart === 0 &&
      event.currentTarget.selectionEnd === 0
    ) {
      event.preventDefault();
      exitShell();
    }
  };
  const stopTurn = useCallback(() => {
    if (Date.now() - sentAt.current > STOP_GUARD_MS) {
      refocusField.current = document.activeElement === sendButton.current;
      onStop();
    }
  }, [onStop]);
  // The native command palette and keyboard route Stop Agent Turn through this same composer
  // callback. Ignore a stale action after the turn ended while the page was switching sessions.
  const actionSessionId = snapshot.sessionId;
  const actionWorking = snapshot.isWorking;
  useEffect(() => {
    const stopFromAction = (event: Event) => {
      const detail =
        event instanceof CustomEvent && event.detail && typeof event.detail === "object" ? event.detail : undefined;
      const requestedSessionId =
        detail && "sessionId" in detail && typeof detail.sessionId === "string" ? detail.sessionId : undefined;
      stopTurnFromAction(
        { sessionId: actionSessionId, isWorking: actionWorking },
        requestedSessionId,
        actionSessionId,
        stopTurn,
      );
    };
    window.addEventListener("cmux-acpmux-stopTurn", stopFromAction);
    return () => window.removeEventListener("cmux-acpmux-stopTurn", stopFromAction);
  }, [actionSessionId, actionWorking, stopTurn]);
  // Enter sends unless it picks a command: with the menu closed, with nothing to pick (an unknown
  // command or a pasted path), or on a command already typed in full that takes no arguments.
  const returnSends = () => {
    const typedInFull =
      (matches[selected] ? shownName(matches[selected].command) : undefined) === query &&
      (!matches[selected]?.command.hint || matches[selected]?.command.source === "cmux");
    return !open || matches.length === 0 || typedInFull;
  };
  const sendOnReturn = (event: { preventDefault(): void }) => {
    if (!returnSteers) return submit(event);
    event.preventDefault();
    return send(false, true);
  };
  // The Return an input method or Dictation passed on (keyCode 229) reaches no key handler, and
  // the browser inserts its paragraph instead (Leo's dictated prompt, d5829ff). Return never adds
  // a line here (Shift-Return does): it sends, or picks the menu's command, as a Return key would.
  const returnInput = () => {
    if (shell) return;
    if (mentionAt && mentions[mentionSelected]) return pickMention(mentions[mentionSelected]);
    if (returnSends()) return void sendOnReturn({ preventDefault() {} });
    if (matches.length > 0) pick(matches[selected].command);
  };
  const keyDown = (event: KeyboardEvent) => {
    // Every key belongs to the input method while it composes, not only Enter.
    if (event.isComposing || event.keyCode === 229) return;
    if (interrupt(event)) return;
    const plain = !event.shiftKey && !event.altKey && !event.metaKey && !event.ctrlKey;
    // Tab takes the suggested prompt into the field; the next Tab moves focus on as usual. Esc puts
    // it away for this chat (and still does whatever Esc does there).
    if (suggested && plain && event.key === "Tab") {
      event.preventDefault();
      if (field.current) field.current.type(suggested);
      else {
        setText(suggested);
        setCaret(suggested.length);
      }
      return;
    }
    if (suggested && plain && event.key === "Escape") setSuggestionDismissed(suggestionKey);
    // While a turn runs, ⌘Return queues the prompt for after it; Return steers (below). Nothing
    // sent from the composer stops the turn: only Stop and Esc do (Leo 2026-10-20). (The Quick
    // Composer keeps its own ⌘Return and Esc, below.)
    const quick = Boolean(onOpenInWindow);
    const commandReturn =
      event.key === "Enter" && event.metaKey && !event.shiftKey && !event.altKey && !event.ctrlKey && !quick;
    if (commandReturn && queues && (text.trim() || attachments.length > 0)) {
      event.preventDefault();
      send(false, steersAlways);
      return;
    }
    // ⌘Return on an empty prompt after a turn answers the recap card's question (RecapCard.tsx).
    if (
      commandReturn &&
      onEmptyCommandReturn &&
      !shell &&
      remote.canSend &&
      !snapshot.isWorking &&
      !text.trim() &&
      attachments.length === 0
    ) {
      event.preventDefault();
      onEmptyCommandReturn();
      return;
    }
    // The @ picker owns arrows (and Ctrl-N/P/J/K), Return and Tab while it lists files, and Esc.
    if (mentionAt) {
      if (event.key === "Escape") {
        event.preventDefault();
        event.stopPropagation();
        setMentionDismissed(text);
        return;
      }
      const control = event.ctrlKey && !event.metaKey && !event.altKey && !event.shiftKey;
      const step =
        (event.key === "ArrowDown" && plain) || (control && (event.key === "n" || event.key === "j"))
          ? 1
          : (event.key === "ArrowUp" && plain) || (control && (event.key === "p" || event.key === "k"))
            ? -1
            : 0;
      if (step && mentions.length > 0) {
        event.preventDefault();
        const next = mentionSelected < 0 ? (step > 0 ? 0 : mentions.length - 1) : mentionSelected + step;
        setMentionActive(mentions[(next + mentions.length) % mentions.length]!.key);
        return;
      }
      if ((event.key === "Enter" || event.key === "Tab") && plain && mentions[mentionSelected]) {
        event.preventDefault();
        pickMention(mentions[mentionSelected]);
        return;
      }
    }
    // ↑ on an empty prompt goes to the queue's last prompt (ComposerQueue.tsx has its keys).
    if (event.key === "ArrowUp" && plain && !open && !text.trim() && ownQueue(snapshot.queue).length) {
      // The list draws at the top of the form, over the strip (ComposerQueue.tsx).
      const chat = form.current?.closest(".acpmux-main") ?? form.current;
      // A long queue's fold ("N more queued") sits under its rows, so ↑ reaches it first.
      const rows = chat?.querySelectorAll<HTMLElement>(
        ".acpmux-composer-queue .acpmux-queued, .acpmux-queue-foldbar .acpmux-queue-fold",
      );
      const last = rows?.[rows.length - 1];
      if (last) {
        event.preventDefault();
        last.focus();
        return;
      }
    }
    // ↑ and ↓ on an empty prompt (or one they brought back) step through the chat's prompts. In a
    // recalled prompt of several lines they move the caret first, and recall from its first (↑)
    // or last (↓) line.
    if ((event.key === "ArrowUp" || event.key === "ArrowDown") && plain && !open && !shell) {
      const up = event.key === "ArrowUp";
      const lines = recalling ? field.current?.text() : undefined;
      const edge =
        !lines ||
        (up
          ? !lines.value.slice(0, lines.selectionStart).includes("\n")
          : !lines.value.slice(lines.selectionEnd).includes("\n"));
      const recalled = edge ? prompts.step(up ? -1 : 1, field.current?.agentText(text) ?? text) : undefined;
      if (recalled !== undefined) {
        event.preventDefault();
        if (recalled === null) return;
        pendingCaret.current = recalled.length;
        edit(recalled, recalled.length);
        return;
      }
    }
    // Esc stops a running turn, as Stop does, with or without a draft (the draft stays; with one
    // typed, Send takes Stop's slot, so Esc is the composer's way to stop): by default the second of two presses
    // does (escapeStop.ts), and the first arms Stop: it keeps its glyph, takes the accent and is named
    // "Press Esc again to stop". Menus, pickers and the
    // @ list take their Esc above, so one press still closes them.
    if (event.key === "Escape" && plain && !open && running && !stopping && !quick) {
      event.preventDefault();
      // Holding Esc down is one press: its auto-repeat is not the second.
      escapeStop.press(event.repeat);
      return;
    }
    // Esc with nothing to stop lets go of the keyboard, as Claude desktop's does: the caret goes, and a
    // printed key or a click brings it back (composerFocus.ts). Menus and pickers took theirs above.
    if (event.key === "Escape" && plain && !open && !quick) {
      const focused = document.activeElement;
      if (focused instanceof HTMLElement && form.current?.contains(focused)) focused.blur();
      return;
    }
    // ⌘Return sends whatever is typed, even over an open command menu, then opens the window.
    if (
      onOpenInWindow &&
      event.key === "Enter" &&
      event.metaKey &&
      !event.shiftKey &&
      !event.altKey &&
      !event.ctrlKey
    ) {
      event.preventDefault();
      const typed = typedWords().trim() !== "";
      const sendAndOpen = () => {
        const sent = submitNow.current(false, steersAlways);
        // A prompt the host refused stays in the composer, and the chat stays here.
        if (typed && !sent) return;
        openInWindow.current?.(sent);
      };
      // Owned commands (especially /import) must open their picker immediately, even while an
      // earlier screenshot is still being read. Ordinary prompts retain Return's attachment wait.
      const owned =
        composerCommand(typedWords().trim(), snapshot.summary?.harness, attachments.length)?.kind === "cmux";
      if (!owned && holdForAttachments(sendAndOpen)) return;
      sendAndOpen();
      return;
    }
    if (event.key === "Enter" && plain && returnSends()) {
      sendOnReturn(event);
      return;
    }
    if (!open) return;
    if (event.key === "Escape") {
      event.preventDefault();
      event.stopPropagation();
      const plus = plusDraft.current;
      plusDraft.current = undefined;
      if (plus && plus.written === text) {
        edit(plus.original, plus.original.length);
        pendingCaret.current = plus.original.length;
        return;
      }
      setDismissed(text);
      return;
    }
    if (matches.length === 0) return;
    const control = event.ctrlKey && !event.metaKey && !event.altKey && !event.shiftKey;
    if (event.key === "ArrowDown" || event.key === "ArrowUp" || (control && (event.key === "j" || event.key === "k"))) {
      event.preventDefault();
      const step = event.key === "ArrowDown" || event.key === "j" ? 1 : -1;
      setActive((selected + step + matches.length) % matches.length);
    } else if ((event.key === "Enter" || event.key === "Tab") && plain) {
      event.preventDefault();
      pick(matches[selected].command);
    }
  };

  promptBeforeInput.current = (data, state) => {
    typedAt.current = performance.now();
    // `!` first: shell mode, in place. A pasted `!cmd` keeps what follows the `!`.
    if (!onShell || state.composing || !state.empty || !data.startsWith("!")) return false;
    enterShell(data.slice(1));
    return true;
  };
  // Only the person's own edit is typing: a change right after their keystroke, text input or
  // IME composition. A value applied from outside (a draft coming back on open or a switch, a
  // failed prompt restored, the field normalizing either) comes with none.
  promptChange.current = (value, at) => {
    edit(value, at);
    if (performance.now() - typedAt.current >= TYPED_WINDOW_MS) return;
    if (hydratedSession.current !== sessionId) editedBeforeHydration.current = true;
    // Kept past this mount: a composer that comes back keeps the person's text over acpmux's.
    noteDraftEdited(sessionId);
    // One change per key: what the field does after it (normalizing) is not another.
    typedAt.current = Number.NEGATIVE_INFINITY;
    if (sessionId && value.trim()) onTyping?.(value, sessionId);
  };
  promptCaret.current = setCaret;
  promptKeyDown.current = (event) => {
    const key = event.key.length === 1 ? event.key.toLowerCase() : event.key;
    const edits = event.metaKey
      ? CMD_EDIT_KEYS.has(key)
      : event.ctrlKey
        ? CTRL_EDIT_KEYS.has(key)
        : !NOT_AN_EDIT_KEY.has(event.key);
    if (edits) typedAt.current = performance.now();
    return keyDown(event);
  };
  promptReturnInput.current = returnInput;
  promptComposition.current = (value) => {
    typedAt.current = performance.now();
    composing.current = value;
  };

  // Stop was sent and the turn has not ended: Stop turns and says so.
  const stopping = !shell && snapshot.isWorking && snapshot.stopping === true;
  // A prompt held while the chat's agent starts (harnessSwitch.ts) reads as its turn already
  // running: Stop is there from the send on and takes the held prompts back to the composer (the
  // transcript draws no Cancel for them, Leo 2026-11-01), then stops the turn once it runs.
  const holding =
    !snapshot.isWorking &&
    snapshot.switching?.phase === "starting" &&
    snapshot.rows.some((row) => row.queued !== undefined);
  const stop = !shell && (snapshot.isWorking || holding) && !text.trim();
  // Stop shows for the whole turn, a typed prompt or not; Esc stops only from an empty prompt.
  const running = !shell && (snapshot.isWorking || holding);
  const hasDraft = Boolean(text.trim() || attachments.length || pending.length);
  // Esc stops the turn on a double press (escapeStop.ts). The Quick Composer's page-level Esc hides
  // its panel, so only the pane counts an Esc that reaches the page.
  const escapeStop = useEscapeStop({
    stoppable: running && !stopping,
    session: sessionId,
    double: escapeDoublePress,
    pageEscape: !onOpenInWindow,
    onStop: stopTurn,
  });
  // While a turn runs, what is sent waits behind it, so the empty prompt says so.
  const queues = !shell && snapshot.isWorking && remote.canSend && !blockSend && !blocked?.reason;
  // An agent that steers takes Return into the running turn: it reads the prompt when its current
  // step ends, and nothing is cancelled. ⌘Return queues the prompt for after the turn (Claude's
  // keys, Leo 2026-10-20). Attachments go along, so staged files alone can steer too. An agent
  // that cannot steer queues on both keys.
  // One of the agent's own slash commands waits for the turn either way (cliOnlyCommands.ts): it
  // queues, so it shows as waiting behind the turn and runs as its own turn, never as a steer.
  const steers =
    queues && snapshot.summary?.steering === true && !commandWaitsForTurn(text, snapshot.summary?.harness, commands);
  const returnSteers = steers && (Boolean(text.trim()) || attachments.length > 0);
  // Queueing off (ChatGPT's and Codex's "Turn off queueing", queueing.ts): ⌘Return and Send steer
  // too, so nothing new waits. An agent that cannot steer still runs it after the turn.
  const steersAlways = steers && !queueing;
  // Mid-turn it teaches both keys, as Claude's composer does: Return steers and ⌘Return queues.
  // The Quick Composer's ⌘Return opens the window, so there it names Return alone; an agent that
  // cannot steer says it queues.
  // While the double press is armed, the placeholder says to press Esc again, as Stop's hint does;
  // once Stop is sent, it says the turn is stopping until it ends.
  const placeholderKey = stopping
    ? COMPOSER_LABELS.stopping
    : escapeStop.armed
      ? COMPOSER_LABELS.escapeAgainToStop
      : !queues
        ? COMPOSER_LABELS.placeholder
        : !steers
          ? COMPOSER_LABELS.placeholderQueued
          : onOpenInWindow || steersAlways
            ? COMPOSER_LABELS.placeholderSteerQuick
            : COMPOSER_LABELS.placeholderSteer;
  // A side session's idle prompt reads "Reply in this session…" (the `placeholder` prop); the
  // mid-turn and Esc hints still win, since they say what a key does now.
  const placeholderText =
    placeholder && placeholderKey === COMPOSER_LABELS.placeholder ? placeholder : t(placeholderKey);
  // An idle new chat suggests the open PR another chat in this checkout made, Tab to take it
  // (promptSuggestion.ts; Leo 2026-10-18). It never sends: Tab writes it, Return sends it.
  const cwd = snapshot.summary?.cwd;
  const branch = snapshot.summary?.branch;
  // The chat folder's own PR, which the App reads with gh for the header's chip: no session summary
  // reports a PR yet, so this is the live source.
  const headerPullRequest = useHeaderState().pullRequest;
  const headerHere = headerCwd === undefined || folder(headerCwd) === folder(cwd);
  const livePullRequest = useMemo<LivePullRequest | undefined>(
    () =>
      headerPullRequest && headerHere
        ? {
            number: headerPullRequest.number,
            title: headerPullRequest.title,
            state: headerPullRequest.state,
            checks: headerPullRequest.checks.state,
          }
        : undefined,
    [headerPullRequest, headerHere],
  );
  // A new chat before its first send, known as one (locationRow.ts): the location strip and the
  // suggested prompt are a new chat's. An existing chat opening or loading its rows has neither.
  const locationVisible = showsLocationRow(snapshot, chatKnown);
  const suggestion = useMemo<PromptSuggestion | undefined>(
    () =>
      locationVisible &&
      !shell &&
      !snapshot.isWorking &&
      snapshot.rows.length === 0 &&
      remote.canSend &&
      !blockSend &&
      !blocked?.reason
        ? promptSuggestion(
            snapshot.sessions,
            { sessionId: snapshot.sessionId, cwd, branch },
            Date.now(),
            livePullRequest,
          )
        : undefined,
    [
      locationVisible,
      shell,
      snapshot.isWorking,
      snapshot.rows.length,
      remote.canSend,
      blockSend,
      blocked,
      snapshot.sessions,
      snapshot.sessionId,
      cwd,
      branch,
      livePullRequest,
    ],
  );
  const suggestionKey = suggestion && `${snapshot.sessionId ?? ""}|${cwd}|${suggestion.number}`;
  // Exactly empty, as the field draws its placeholder: a typed space hides the suggestion, so Tab
  // must not take it then.
  const suggested =
    suggestion && !dictating && suggestionKey !== suggestionDismissed && text === "" && attachments.length === 0
      ? t(
          suggestion.kind === "failing"
            ? COMPOSER_LABELS.suggestFailing
            : suggestion.kind === "draft"
              ? COMPOSER_LABELS.suggestDraft
              : COMPOSER_LABELS.suggestOpen,
          { number: String(suggestion.number), title: suggestion.title },
        )
      : undefined;
  // Focus leaving the composer closes the menu and takes back what + wrote.
  const blur = (event: React.FocusEvent<HTMLFormElement>) => {
    if (event.currentTarget.contains(event.relatedTarget as Node | null)) return;
    unsentDraft.current?.flush();
    const original = unwrapped();
    plusDraft.current = undefined;
    if (original !== text) edit(original, original.length);
    else if (open) setDismissed(text);
    else if (mentionAt) setMentionDismissed(text);
  };
  // The prompt's context menu, as a text field's (POLISH.md): Undo and Redo, the edit items and
  // Select All, then Attach Files… and Insert Mention. Cut and Copy need a selection in the field,
  // and Undo and Redo an edit in its history, read when the menu opens.
  const [fieldSelected, setFieldSelected] = useState(false);
  const [fieldHistory, setFieldHistory] = useState({ undo: false, redo: false });
  const noteSelection = () => {
    const shellInput = shellField.current;
    if (shell && shellInput) {
      setFieldSelected(shellInput.selectionStart !== shellInput.selectionEnd);
      // A plain text area keeps its own history, which the page cannot read: both stay offered.
      setFieldHistory({ undo: true, redo: true });
      return;
    }
    const selection = window.getSelection();
    const element = field.current?.element();
    setFieldSelected(Boolean(selection && !selection.isCollapsed && element?.contains(selection.anchorNode)));
    setFieldHistory(field.current?.history() ?? { undo: false, redo: false });
  };
  /// Undo, Redo or Select All, in the prompt or the shell field.
  const runField = (command: "undo" | "redo" | "selectAll") => {
    const shellInput = shellField.current;
    if (shell && shellInput) {
      shellInput.focus();
      if (command === "selectAll") shellInput.select();
      else document.execCommand(command);
      return;
    }
    field.current?.focus();
    field.current?.[command]();
  };
  /// Focuses the prompt that shows: the shell line in shell mode (the Markdown field is hidden then).
  const focusPrompt = () => (shell ? shellField.current : field.current)?.focus();
  const runEdit = (command: ComposerEditCommand) => {
    focusPrompt();
    if (command === "pasteAsPlainText") box.current?.plainPaste();
    onEdit?.(command);
  };
  const fieldMenu: ContextMenuItem[] = [
    {
      id: "undo",
      label: t(COMPOSER_LABELS.undo),
      disabled: !fieldHistory.undo,
      onSelect: () => runField("undo"),
    },
    {
      id: "redo",
      label: t(COMPOSER_LABELS.redo),
      disabled: !fieldHistory.redo,
      onSelect: () => runField("redo"),
    },
    {
      id: "cut",
      label: t(COMPOSER_LABELS.cut),
      separatorBefore: true,
      disabled: !onEdit || !fieldSelected,
      onSelect: () => runEdit("cut"),
    },
    {
      id: "copy",
      label: t(COMPOSER_LABELS.copy),
      disabled: !onEdit || !fieldSelected,
      onSelect: () => runEdit("copy"),
    },
    {
      id: "paste",
      label: t(COMPOSER_LABELS.paste),
      disabled: !onEdit,
      onSelect: () => runEdit("paste"),
    },
    {
      id: "pasteAsPlainText",
      label: t(COMPOSER_LABELS.pasteAsPlainText),
      disabled: !onEdit,
      onSelect: () => runEdit("pasteAsPlainText"),
    },
    { id: "selectAll", label: t(COMPOSER_LABELS.selectAll), onSelect: () => runField("selectAll") },
    {
      id: "attach",
      label: t(COMPOSER_LABELS.attachFiles),
      separatorBefore: true,
      onSelect: () => chooser.current?.click(),
    },
    {
      id: "mention",
      label: t(COMPOSER_LABELS.insertMention),
      disabled: shell,
      onSelect: () => mention(),
    },
    {
      id: "scrollToBottomOnSend",
      label: t(COMPOSER_LABELS.scrollToBottomOnSend),
      checked: scrollToBottomOnSend,
      separatorBefore: true,
      onSelect: () => setScrollToBottomOnSend(!scrollToBottomOnSend),
    },
  ];

  // The location strip: the folder and computer chips over the card (hq#1957 composer location
  // strip, composerLocation.css), so the card holds one controls row. Only a new chat has the visible
  // strip, before its first send (locationRow.ts): a started chat cannot change folder or machine.
  // Keep a non-painting slot for that strip while the first prompt changes the transcript. The
  // composer is bottom-anchored, so removing the slot in the same render would move every control
  // by the strip's height (cx-ncc.58); the slot is hidden when a queue is present, whose own height
  // becomes the top strip.
  const locationKey = snapshot.sessionId ?? snapshot.summary?.sessionId;
  // A gallery or a reopened pane can render an unselected snapshot before its session arrives.
  // Do not let that transient visible strip reserve space for a different, already-started chat.
  // A slot is meaningful only after the visible strip was observed for a known session identity.
  const locationWasVisible =
    locationSlotWasShown.current && locationKey !== undefined && locationSlotSession.current === locationKey;
  if (locationVisible && locationKey !== undefined) {
    locationSlotSession.current = locationKey;
    locationSlotWasShown.current = true;
  } else if (!locationWasVisible) {
    locationSlotSession.current = undefined;
    locationSlotWasShown.current = false;
  }
  const keepLocationSlot = !locationVisible && locationWasVisible && ownQueue(snapshot.queue).length === 0;
  const context = locationVisible ? (
    <ComposerContext
      projectChoices={projectChoices}
      machineFolders={machineFolders}
      onBrowseProject={onBrowseProject}
      onNewWorktree={onNewWorktree}
      onBrowseFolder={onBrowseFolder}
      onConnect={onConnect}
      {...(onOffload ? { onOffload } : {})}
      {...(offloads ? { offloads } : {})}
      summary={snapshot.summary}
      sessions={snapshot.sessions}
      peers={snapshot.peers}
      {...(snapshot.peerKinds ? { peerKinds: snapshot.peerKinds } : {})}
      {...(snapshot.peerConnected ? { peerConnected: snapshot.peerConnected } : {})}
      {...(snapshot.peerStates ? { peerStates: snapshot.peerStates } : {})}
      {...(snapshot.peerResources ? { peerResources: snapshot.peerResources } : {})}
      {...(onRefreshMachines ? { onRefreshMachines } : {})}
      {...(folderNote ? { folderNote } : {})}
      {...(runMode ? { runMode } : {})}
      environments={environments}
      {...(onComputer ? { onComputer } : {})}
      onProject={
        onProject &&
        ((cwd, peer) => {
          onProject(cwd, peer);
          field.current?.focus();
        })
      }
      localName={localName}
      onNewChat={onNewChat}
      closeOnTrustAsk={closeOnTrustAsk}
    />
  ) : keepLocationSlot ? (
    <div className="acpmux-composer-strip-placeholder" aria-hidden="true" />
  ) : null;
  // Stop, while a turn runs and the prompt is empty, in the one send slot (sendControl, below).
  // Once sent, Stop turns until the turn ends, so a press (or Esc) is seen to take (Leo 2026-10-21:
  // "IDK IF IM ACTUALLY STOPPING YOU"); pressed again it sends Stop again.
  const stopLabel = t(
    stopping ? COMPOSER_LABELS.stopping : escapeStop.armed ? COMPOSER_LABELS.escapeAgainToStop : COMPOSER_LABELS.stop,
  );
  const stopButton = running ? (
    <button
      key="stop"
      ref={sendButton}
      type="button"
      className="acpmux-send acpmux-cancel"
      data-escape-armed={escapeStop.armed && !stopping ? "" : undefined}
      data-stopping={stopping ? "" : undefined}
      aria-label={stopLabel}
      // tooltip-allow: names the icon-only Stop, once armed says to press Esc again, and once sent says it is stopping.
      title={stopLabel}
      onClick={stopTurn}
    >
      {/* The first Esc of the double press keeps the glyph; its color and name say Esc again stops. */}
      {stopping ? <Spinner loading size={14} /> : <StopIcon />}
    </button>
  ) : null;
  // A draft of attachments alone is still a draft: it gets Send, never Stop alone.
  const sendOrStop =
    stop && !hasDraft ? (
      stopButton
    ) : remote.canSend && (!quietActions || shell || hasDraft) ? (
      // One send control in both looks (Leo 2026-10-31: "THE F***ING TWO SEND
      // BUTTONS"): mid-turn the empty prompt's slot is Stop, and the first letter turns it
      // into Send, which does what Return does: it steers an agent that steers, else queues.
      // The box draws no Send at rest until there is a draft, the mic alone on the right; its
      // one slot sits before the mic with Claude desktop's ↵, so the mic keeps the right edge
      // through a turn, in both looks.
      <button
        key="send"
        ref={sendButton}
        type="submit"
        disabled={Boolean(authBlock || authBlocked || blockSend || blocked?.reason) && !shell}
        className={`acpmux-send${(shell ? shellText.trim() : !blockSend && !blocked?.reason && hasDraft) ? " acpmux-send-ready" : ""}`}
        aria-label={shell ? t("composer.shellRun") : t(COMPOSER_LABELS.send)}
        title={
          shell
            ? t("composer.shellRun")
            : escapeStop.armed && !stopping
              ? t(COMPOSER_LABELS.escapeAgainToStop)
              : authBlock
                ? authBlock
                : blocked?.reason
                  ? t(blocked.reason)
                  : t(
                      !snapshot.isWorking
                        ? "composer.sendTooltip"
                        : steersAlways || returnSteers
                          ? "composer.steerTooltip"
                          : "composer.queueTooltip",
                    )
        }
      >
        {quietActions && !shell ? <ReturnIcon /> : <ArrowUpIcon />}
      </button>
    ) : null;
  // The Quick Composer's Esc hides its panel, so Esc cannot stop a turn there: with a draft typed it
  // keeps Stop beside its one Send (one stop and one send, never two sends).
  const sendControl =
    onOpenInWindow && running && hasDraft && sendOrStop ? (
      <>
        {stopButton}
        {sendOrStop}
      </>
    ) : (
      sendOrStop
    );
  // Why a failed turn paused the queue: the paused note names it (queuePause.ts).
  const pauseReason = snapshot.summary?.queuePaused === true ? queuePauseReason(snapshot.rows) : undefined;
  return (
    <form
      ref={form}
      className="acpmux-composer"
      // A web update's reload gives the prompt the keyboard back (pages/shared/webSwap.ts).
      {...{ [WEB_SWAP_FOCUS]: "composer" }}
      data-cmux-component="Composer"
      data-cmux-source="webviews/src/agent-session/acpmux/Composer.tsx:1420"
      data-shell={shell ? "" : undefined}
      // Codex's look (composerLook.ts, composerLocation.css); none is Claude's, the default.
      data-composer-look={look === "codex" ? "codex" : undefined}
      // The box inside draws the compact grid in both looks (ComposerBox.tsx, composerLocation.css).
      data-composer-grid=""
      onSubmit={(event) => {
        if (!shell) return submit(event);
        event.preventDefault();
        runShell();
      }}
      onBlur={blur}
      onContextMenuCapture={openChipMenu}
    >
      {remote.note && (
        <p className="acpmux-composer-remote-note" role="note">
          {t(remote.note)}
        </p>
      )}
      {!remote.note && authBlock && (
        <p className="acpmux-composer-remote-note acpmux-composer-trust-note" role="alert">
          {authBlock}
        </p>
      )}
      {!remote.note && !authBlock && blocked?.reason && !blocked.shownAbove && (
        <p className="acpmux-composer-remote-note acpmux-composer-trust-note" role="note">
          {t(blocked.reason)}
        </p>
      )}
      {findingFiles &&
        searchFiles &&
        form.current?.parentElement &&
        createPortal(
          <FileSearch
            search={searchFiles}
            onClose={() => {
              setFindingFiles(false);
              field.current?.focus();
            }}
            onPick={(path) => {
              setFindingFiles(false);
              mention(path);
            }}
          />,
          form.current.parentElement,
        )}
      {/* The bottom stack's queue slot (bottomStack.css): above the strip, in the layout flow. */}
      <ComposerQueue
        // One per chat: a chat's long queue keeps its fold, open or closed, as you switch chats.
        key={snapshot.summary?.sessionId || sessionId}
        chat={snapshot.summary?.sessionId || sessionId}
        queue={snapshot.queue}
        paused={snapshot.summary?.queuePaused === true}
        {...(pauseReason ? { pauseReason } : {})}
        t={t}
        onRemove={onQueueRemove}
        onCancelEdit={onQueueCancelEdit}
        onChange={onQueueChange}
        onLost={onQueueLost}
        onSideChat={onQueueSideChat}
        readImage={queueImage}
        onLeave={() => field.current?.focus()}
      />
      {context}
      {dropHost && (
        <DropOverlay state={drop} onLanded={dropLanded} container={dropHost} landingTarget={landingTarget} />
      )}
      <ComposerBox
        handle={box}
        boxRef={setComposerBox}
        inert={locked}
        fieldRef={fieldRef}
        field={{
          className: shell
            ? "acpmux-composer-prompt is-hidden"
            : `acpmux-composer-prompt${dictating ? " is-dictating" : ""}`,
          value: text,
          selectionKey: sessionId,
          placeholder: dictating ? t("dictation.listening") : (suggested ?? placeholderText),
          placeholderKey: suggested && !dictating ? t(COMPOSER_LABELS.suggestionKey) : undefined,
          attributes: {
            "aria-description": suggested ? `${suggested}. ${t(COMPOSER_LABELS.suggestionHint)}` : undefined,
            role: "combobox",
            "aria-label": t(COMPOSER_LABELS.prompt),
            "aria-multiline": "true",
            "aria-expanded": String(open || Boolean(mentionAt)),
            "aria-controls": open ? "acpmux-slash-menu" : mentionAt ? "acpmux-mention-menu" : undefined,
            "aria-autocomplete": "list",
            "aria-activedescendant":
              open && matches.length > 0
                ? `acpmux-slash-${selected}`
                : mentionAt && mentionSelected >= 0
                  ? `acpmux-mention-${mentionSelected}`
                  : undefined,
            spellcheck: String(spellChecking),
            // WEB-SWAP: the prompt keeps its own draft (composerDraft.ts holds until it is written).
            [WEB_SWAP_KEPT_TEXT]: "",
          },
          onBeforeInput: stablePromptCallbacks.onBeforeInput,
          onChange: stablePromptCallbacks.onChange,
          onCaret: stablePromptCallbacks.onCaret,
          onKeyDown: stablePromptCallbacks.onKeyDown,
          onReturnInput: stablePromptCallbacks.onReturnInput,
          onCompositionChange: stablePromptCallbacks.onCompositionChange,
          onUnplacedQuotes: stablePromptCallbacks.onUnplacedQuotes,
          slashNames,
          onSlash: setSlash,
        }}
        attachments={attachments}
        pending={pending}
        setAttachments={setAttachments}
        attachmentsRef={attachmentsRef}
        attachError={attachError}
        codex={snapshot.summary?.family === "codex" || snapshot.summary?.harness === "codex"}
        onRemoveAttachment={(id) => {
          setAttachments((current) => current.filter((item) => item.id !== id));
          field.current?.focus();
        }}
        onCancelAttachment={(id) => {
          cancel(id);
          field.current?.focus();
        }}
        onRetryAttachment={retry}
        onReviveAttachment={revive}
        originalFailures={originalFailures}
        onPasteFile={(file) => void attach([file], true, "paste")}
        onPasteFiles={(files) => void attach(files, true, "paste")}
        fieldMenu={fieldMenu}
        onFieldMenuOpen={noteSelection}
        fieldOverlay={
          shell && (
            <div className="acpmux-shell-prompt">
              <span className="acpmux-shell-glyph" aria-hidden="true">
                !
              </span>
              <textarea
                ref={shellField}
                className="acpmux-shell-field"
                rows={1}
                value={shellText}
                aria-label={t("composer.shell")}
                placeholder={t("composer.shellPlaceholder")}
                spellCheck={spellChecking}
                autoCapitalize="off"
                autoCorrect="off"
                onChange={(event) => setShellText(event.target.value)}
                // ui-allow: the shell field's own editing keys (Enter runs, Esc or empty Backspace leaves, Ctrl-C stops).
                onKeyDown={shellKeyDown}
              />
            </div>
          )
        }
        top={
          <>
            <input
              ref={importInput}
              className="acpmux-import-input"
              type="file"
              accept=".jsonl,.json,text/plain,application/json"
              // The /import picker: never shown or focused; the label is the command's language-neutral name.
              hidden
              aria-label="/import"
              onChange={(event) => {
                const file = event.currentTarget.files?.[0];
                event.currentTarget.value = "";
                if (importSandboxed) {
                  setAttachError(t("composer.cmuxImportSandbox"));
                  return;
                }
                if (file)
                  void Promise.resolve()
                    .then(() => onImportFile?.(file))
                    .catch((error: unknown) => setAttachError(error instanceof Error ? error.message : String(error)));
              }}
            />
            {/* Anchored to the field, like the picker menus, so a queue above it never pushes the menu up.
                Drawn out of the box's glass, so their own glass frosts the transcript (backdropLayer.tsx). */}
            {open && (
              <ComposerListLayer>
                <SlashMenu
                  matches={matches}
                  active={selected}
                  empty={!commands?.length ? t(COMPOSER_LABELS.noCommands) : t(COMPOSER_LABELS.noMatchingCommands)}
                  fast={fastModeState(snapshot.summary?.configOptions)}
                  onHover={setActive}
                  onPick={pick}
                />
              </ComposerListLayer>
            )}
            {mentionAt && (
              <ComposerListLayer>
                <MentionMenu
                  state={searchFiles ? mentionSearch : undefined}
                  items={mentions}
                  active={mentionSelected}
                  onHover={(index) => setMentionActive(mentions[index]?.key)}
                  onPick={pickMention}
                />
              </ComposerListLayer>
            )}
          </>
        }
        onCardPress={focusPrompt}
        leading={
          <>
            <input
              ref={chooser}
              className="acpmux-attach-input"
              type="file"
              multiple
              hidden
              aria-label={t(COMPOSER_LABELS.attach)}
              onChange={(event) => {
                const files = [...(event.currentTarget.files ?? [])];
                // Cleared, choosing the same file again still fires change.
                event.currentTarget.value = "";
                // The person chose these files: what the composer can't attach is saved for the chat,
                // and the host says where each came from (its own metadata: Screenshot, a download).
                void attach(files, true, "choose");
              }}
            />
            {leading !== undefined ? (
              leading
            ) : (
              <ComposerPlusMenu
                planning={planning}
                entries={composerPlusRegistry({
                  commands,
                  recentCommands: recentCommands(recentCommandNames, commands),
                  translate: t,
                  extensions: plusExtensions,
                  canCapture: Boolean(capture && allowImages),
                  canChooseProject: locationVisible && Boolean(projectChoices || onBrowseProject),
                  ...(planChoice && plan
                    ? { planMode: { id: plan.id, name: planChoice.name, description: t("picker.planHint") } }
                    : {}),
                }).filter((entry) => {
                  if (entry.id === "files.search") return Boolean(searchFiles);
                  if (entry.id === "add.commands") return Boolean(commands?.length);
                  return true;
                })}
                onCommand={(action, modeId) => {
                  if (action === "composer.attachFiles") chooser.current?.click();
                  else if (action === "composer.attachScreenshot" || action === "composer.attachWindow") {
                    void capture?.(action === "composer.attachWindow" ? "window" : "screen")
                      .then(async (shot) => {
                        if (shot instanceof File) await attach([shot]);
                        else if (shot) setAttachError(attachmentErrorText(shot, t));
                      })
                      .finally(() => {
                        const focused = document.activeElement;
                        if (!focused || focused === document.body || form.current?.contains(focused))
                          field.current?.focus();
                      });
                  } else if (action === "composer.chooseProject") openPicker("Location");
                  else if (action === "composer.planMode" && modeId) togglePlan(modeId);
                  else if (action === "composer.mention") mention();
                  else if (action === "searchFiles") setFindingFiles(true);
                  else if (action === "composer.commands") openCommands();
                }}
                {...(onPlusCommand ? { onExtension: onPlusCommand } : {})}
                onSlash={pickFromPlus}
                onOpen={() => setRecentCommandNames(loadRecentCommandNames())}
              />
            )}
          </>
        }
        chips={
          <PromptFocus value={focusPrompt}>
            <Chips snapshot={snapshot} />
          </PromptFocus>
        }
        // Claude Code ends the quiet row on the context ring. It keeps its place before the chat
        // reports usage (inert, ContextRing), so the first report moves nothing in the row
        // (hq#1957: the composer holds still while a turn runs); the context-usage setting
        // hides it (showContextUsage).
        ring={
          showContextUsage && (
            <ContextRing
              used={usage?.used}
              size={usage?.size}
              setup={usage?.setup}
              breakdown={snapshot.summary?.contextBreakdown}
              onOpenDetails={onOpenContext}
            />
          )
        }
        actionsLead={quietActions ? sendControl : undefined}
        accessory={accessory}
        trailing={quietActions ? undefined : sendControl}
        chromeItems={chrome.all}
        // The look dots in the bottom area, on hover (LookSwitch.tsx); the Quick Composer has none.
        {...(onOpenInWindow ? {} : { bottom: <LookSwitch onDone={focusPrompt} /> })}
      />
    </form>
  );
}

/// One attachment above the prompt. An image draws a thumbnail in its own shape and opens in the chat's image
/// viewer on a click; one the pane cannot draw falls back to its name, never an empty square.
function SlashMenu({
  matches,
  active,
  empty,
  fast,
  onHover,
  onPick,
}: {
  matches: SlashMatch[];
  active: number;
  empty: string;
  /// The chat's fast mode, which the `/fast` row's sentence follows (undefined: not reported).
  fast?: "on" | "off";
  onHover(index: number): void;
  onPick(command: SlashCommand): void;
}) {
  const t = useT();
  const list = useRef<HTMLDivElement>(null);
  // Above the composer's box, or past the window's edge when the pane has no room there (cx-6k6cg).
  // The list draws out of the box (backdropLayer.tsx): the box is what it stands beside.
  const box = useComposerListBox();
  const escape = useEscapingList("top", 6, undefined, box);
  const setList = useCallback(
    (node: HTMLDivElement | null) => {
      list.current = node;
      escape?.(node);
    },
    [escape],
  );
  useLayoutEffect(() => {
    list.current?.querySelector<HTMLElement>(`#acpmux-slash-${active}`)?.scrollIntoView?.({ block: "nearest" });
  }, [active]);
  // A native select or datalist cannot hold the matched-name bolding and descriptions.
  if (matches.length === 0)
    return (
      <div
        className="ui-popup ui-glass acpmux-slash-menu acpmux-slash-empty"
        id="acpmux-slash-menu"
        // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
        role="listbox"
        aria-label={t(COMPOSER_LABELS.commands)}
      >
        {empty}
      </div>
    );
  return (
    <div
      ref={setList}
      className="ui-popup ui-glass acpmux-slash-menu"
      id="acpmux-slash-menu"
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
      role="listbox"
      aria-label={t(COMPOSER_LABELS.commands)}
    >
      {/* Virtual focus: the prompt keeps focus and names the row through aria-activedescendant. */}
      {matches.map((match, index) => {
        // The harness's `/fast` reads as ChatGPT's Fast row (Leo 2026-10-22): the bolt, the plain
        // name, and what picking it does now. Picking it still writes `/fast ` (applyCommand).
        const fastRow = isFastCommand(match.command);
        const fastName = t("picker.tierFast");
        return (
          <div
            key={match.command.name}
            id={`acpmux-slash-${index}`}
            // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
            role="option"
            tabIndex={-1}
            aria-selected={index === active}
            className={
              (index === active ? "acpmux-slash-row acpmux-slash-active" : "acpmux-slash-row") +
              (fastRow ? " acpmux-slash-fast" : "")
            }
            onMouseMove={() => {
              if (index !== active) onHover(index);
            }}
            onMouseDown={(event) => {
              event.preventDefault();
              onPick(match.command);
            }}
          >
            {fastRow && (
              <span className="acpmux-slash-icon">
                <BoltIcon size={14} />
              </span>
            )}
            <span className="acpmux-slash-name">
              {fastRow ? (
                // The typed letters stay bold where the shown name spells the command (English).
                fastName.toLowerCase() === match.command.name.toLowerCase() ? (
                  <Highlighted name={fastName} ranges={match.ranges} />
                ) : (
                  fastName
                )
              ) : (
                <>
                  /<Highlighted name={shownName(match.command)} ranges={match.ranges} />
                </>
              )}
            </span>
            {!fastRow && match.command.hint && <span className="acpmux-slash-hint">{match.command.hint}</span>}
            {match.command.source && match.command.source !== "agent" && (
              <span className="acpmux-slash-source">
                {match.command.source === "skill"
                  ? t("composer.slashSkill")
                  : match.command.source === "prompt"
                    ? t("composer.slashPrompt")
                    : "cmux"}
              </span>
            )}
            <span className="acpmux-slash-description">
              {fastRow
                ? t(
                    fast === "on"
                      ? "composer.slashFastOff"
                      : fast === "off"
                        ? "composer.slashFastOn"
                        : "composer.slashFastToggle",
                  )
                : match.command.descriptionKey
                  ? t(match.command.descriptionKey)
                  : match.command.description}
            </span>
          </div>
        );
      })}
    </div>
  );
}

function Highlighted({ name, ranges }: { name: string; ranges: [number, number][] }) {
  const parts: React.ReactNode[] = [];
  let at = 0;
  for (const [start, end] of ranges) {
    if (start > at) parts.push(name.slice(at, start));
    parts.push(<mark key={start}>{name.slice(start, end)}</mark>);
    at = end;
  }
  if (at < name.length) parts.push(name.slice(at));
  return <>{parts}</>;
}
