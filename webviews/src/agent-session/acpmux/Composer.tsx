import React, { useCallback, useEffect, useImperativeHandle, useLayoutEffect, useMemo, useRef, useState } from "react";
import { createPortal } from "react-dom";
// Send's iMessage colors (--cmux-messages-blue); build-agent-pane-web.sh inlines the sheet.
import "../../theme/messages.css";
import { useEscapingList } from "../../ui/popupHost";
import type { AcpmuxSnapshot, QueueEdit } from "./model";
import { MAX_ATTACHMENTS, type AttachmentError, type ComposerAttachment } from "./attachments";
import type { UploadResult } from "./cloudUploads";
import { cappedShellChips, shellAttachment, type ShellRun } from "./shell/shellRuns";
import type { Project } from "./ProjectChooser";
import { ComposerContext } from "./ComposerContext";
import { showsLocationRow } from "./locationRow";
import { ComposerQueue } from "./ComposerQueue";
import {
  ArrowUpIcon,
  AtIcon,
  BuildIcon,
  PaperclipIcon,
  Picker,
  PlusIcon,
  SearchIcon,
  PlanIcon,
  SlashIcon,
  StopIcon,
  type ComposerPermissionAccess,
} from "./ComposerPickers";
import { FileSearch } from "./FileSearch";
import { FastToggle, SpeedToggleHost, type SpeedTiers } from "./FastToggle";
import { Icon } from "./icons/Icon";
import { MentionMenu, mentionQuery, mentionResults, mentionText, useMentionSearch } from "./MentionMenu";
import { ContextMenu, type ContextMenuItem } from "../../ui/ContextMenu";
import { openChipMenu } from "./composerChipMenu";
import type { Choice } from "./ComposerPickers";
import type { FileSearchSource } from "./fileSearchModel";
import { commandArgs, type CmuxCommand } from "./cmuxCommands";
import { cliOnlyCommand } from "./cliOnlyCommands";
import { applyCommand, matchCommands, slashQuery, type SlashCommand, type SlashMatch } from "./slashCommands";
import {
  flushPendingDraftWrites,
  hasPendingDraftWrite,
  readDurableDraft,
  readPersistedDraft,
  seededText,
  useDraftActionsVersion,
  writePersistedDraft,
} from "./composerDraft";
import { MarkdownField, type MarkdownFieldHandle } from "./MarkdownField";
import { type StringKey, useT } from "./i18n";
import { remoteComposer } from "./remoteEditing";
import { ChromeArea } from "../../ui/HideableChrome";
import { useComposerChrome } from "./composerChrome";
import { useMenuPressGuard } from "./menuPressGuard";
import { useRowFit } from "./composerRowFit";
import { useComposerSettings } from "./composerSettings";
import { usePromptHistory } from "./composer/promptHistory";
import { AttachmentStrip, attachmentErrorText, useAttachmentIntake } from "./composer/attachmentIntake";
import type { SendBlock } from "./useFolderTrustAsk";

/// Composer copy. English defaults until the host passes localized labels, as the rest of the pane does today.
/// How long after a send the Stop button that replaces Send ignores clicks.
const STOP_GUARD_MS = 600;

/// How long typing pauses before a new chat's text goes to the host (`onUnsentDraft`).
const UNSENT_DRAFT_SETTLE_MS = 300;

export type ComposerEditCommand = "cut" | "copy" | "paste" | "pasteAsPlainText";

export const COMPOSER_LABELS = {
  placeholder: "composer.placeholder",
  placeholderQueued: "composer.placeholderQueued",
  placeholderSteer: "composer.placeholderSteer",
  placeholderInterrupt: "composer.placeholderInterrupt",
  add: "composer.add",
  mention: "composer.mention",
  attach: "composer.attach",
  attachScreenshot: "composer.attachScreenshot",
  attachWindow: "composer.attachWindow",
  prompt: "composer.prompt",
  send: "composer.send",
  stop: "composer.stop",
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
  tooMany: "composer.tooMany",
  cut: "composer.menu.cut",
  copy: "composer.menu.copy",
  paste: "composer.menu.paste",
  pasteAsPlainText: "composer.menu.pasteAsPlainText",
  undo: "composer.menu.undo",
  redo: "composer.menu.redo",
  selectAll: "composer.menu.selectAll",
  attachFiles: "composer.menu.attachFiles",
  insertMention: "composer.menu.insertMention",
} as const satisfies Record<string, StringKey>;

/// What the pane can do to the composer from outside it.
export type ComposerHandle = {
  /// Puts a held-back prompt in: `text` before what is typed now, `attachments` before the rest.
  restore(text: string, attachments: ComposerAttachment[]): void;
  /// Adds a chip after the ones held, leaving the prompt as typed (the floating chat's Include
  /// focused tab); one with the same id is replaced. Nothing changes when it holds the most it can.
  attach(attachment: ComposerAttachment): void;
  /// Sends what is typed now, as Enter would, even while `blocked` is still drawn (the user just
  /// answered Trust for the prompt the composer held). False when nothing went.
  send(): boolean;
  /// Puts the caret in the prompt (Edit and Resend).
  focus(): void;
  /// What it holds that acpmux's draft does not, for a page about to let go (`pane.wakeState`):
  /// file chips and shell mode's unrun command. Shell runs and move chips stay with their page.
  wakeState(): ComposerWake;
  /// Puts back what a released page's composer held (the handshake's `wake`).
  wake(state: ComposerWake): void;
};

export type ComposerWake = { attachments?: ComposerAttachment[]; shell?: boolean; shellText?: string };

type Props = {
  snapshot: AcpmuxSnapshot;
  chips: React.ComponentType<{ snapshot: AcpmuxSnapshot; permissionAccess?: ComposerPermissionAccess }>;
  /// Sends a prompt. False when nothing can take it yet (no acpmux), so the prompt keeps it. A
  /// promise holds the prompt in the composer until the host takes it: it clears when the promise
  /// resolves and stays (for the user to send again) when it rejects, so a refusal loses nothing.
  /// `steer`: into the running turn now (⌘Return); otherwise a prompt sent mid-turn waits behind it.
  onSend(text: string, attachments?: ComposerAttachment[], steer?: boolean): boolean | void | Promise<unknown>;
  onStop(): void;
  /// Withdraws a queued prompt (`_acpmux/queue_remove`); false when it already started.
  onQueueRemove?(promptId: string): Promise<boolean>;
  /// Changes a queued prompt (`_acpmux/queue_edit`): its text, its place, or send it now.
  onQueueChange?(promptId: string, edit: QueueEdit): Promise<boolean>;
  /// The text of an edit whose prompt started meanwhile: it goes back in the prompt.
  onQueueLost?(text: string): void;
  /// Text the prompt starts with, such as what a chat opened from another tab inherited.
  /// Each new value fills an empty prompt once, caret at the end; it is never sent by itself.
  draft?: string;
  /// The durable session whose unsent prompt belongs in this composer.
  sessionId?: string;
  /// A harness switch is under way (another provider's model was picked): the session changes
  /// under the prompt, and the typed text stays instead of the new session's empty draft.
  switching?: boolean;
  /// The bar's left button, such as attach; by default + opens the agent's commands. `null` leaves the slot empty.
  leading?: React.ReactNode;
  /// Granted folder trust and chat-wide permission state, rendered inside Access.
  permissionAccess?: ComposerPermissionAccess;
  /// Buttons before Send, such as the dictation mic.
  accessory?: React.ReactNode;
  /// Also receives the prompt field's handle, for dictation, which writes into it as typing does.
  prompt?: React.RefObject<MarkdownFieldHandle | null>;
  /// Receives the composer's handle, which puts a prompt a harness switch held back (its text
  /// and attachments) into the composer.
  handle?: React.Ref<ComposerHandle>;
  /// The context menu's Cut, Copy, Paste and Paste as Plain Text: the host runs the web view's own
  /// editing command (`pane.edit`). Without it those items are disabled.
  onEdit?(command: ComposerEditCommand): void;
  /// Handles a cmux-owned slash command after the user submits it.
  onCmuxCommand?(command: CmuxCommand, args?: string): boolean | void;
  /// A new chat's typed text, before it has a session (acpmux keeps a session's draft): the host
  /// keeps it with the tab, so a relaunch opens the chat with it (cx-z5vd).
  onUnsentDraft?(text: string): void;
  /// Reads a transcript chosen by the cmux-owned `/import` command.
  onImportFile?(file: File): void | Promise<void>;
  /// Searches the session's files; the + menu offers Search files only when set.
  searchFiles?: FileSearchSource;
  /// The + menu's Attach Screenshot… and Attach Window… (cx-ncc.71): the host's capture of a region
  /// or a window, attached as an image; an error for one too large to attach (shown as the
  /// composer's note); undefined when the person cancelled the pick.
  capture?(mode: "screen" | "window"): Promise<File | AttachmentError | undefined>;
  /// Sends dropped or pasted files the composer can't attach to the chat's Cloud machine (a moved
  /// chat): their machine paths go into the prompt. Undefined when this chat takes none.
  upload?(files: File[]): Promise<UploadResult>;
  /// Starts a new chat in another project; the tray's project pill chooses only when set.
  onProject?(cwd: string, peer?: string): void;
  projectChoices?: Project[];
  onBrowseProject?(): void;
  /// New Worktree: a new chat on this Mac starts in a worktree of its folder (cx-lyqio.2).
  onNewWorktree?(cwd: string): void;
  /// A started chat's Choose folder…: the host's folder panel (see ComposerContext).
  onBrowseFolder?(): Promise<string | undefined>;
  /// The location row's SSH… and cmux Cloud… rows open the host's connect flows.
  onConnect?(kind: "ssh" | "cloud"): void;
  /// This Mac's name for the location row.
  localName?: string;
  /// A started chat's folder menu: a new chat in `cwd`, in a tab of its own.
  onNewChat?(cwd: string): void;
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
  /// Set while no prompt may go (the folder's trust question is open, useFolderTrustAsk.ts):
  /// Send is off, Enter keeps the prompt, and `reason` shows above it. Shell mode still runs.
  blocked?: SendBlock;
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
  chips: Chips,
  onSend,
  onStop,
  onQueueRemove,
  onQueueChange,
  onQueueLost,
  draft,
  leading,
  permissionAccess,
  accessory,
  prompt,
  onEdit,
  onCmuxCommand,
  onUnsentDraft,
  onImportFile,
  searchFiles,
  capture,
  upload,
  onProject,
  projectChoices,
  onBrowseProject,
  onNewWorktree,
  onBrowseFolder,
  onConnect,
  localName,
  onNewChat,
  onShell,
  onShellInterrupt,
  onMode,
  onOpenInWindow,
  onEmptyCommandReturn,
  onShellChange,
  handle,
  sessionId,
  switching,
  blocked,
}: Props) {
  const t = useT();
  const chrome = useComposerChrome();
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
  // The @ file picker (MentionMenu.tsx): its highlight, and the prompt text Esc closed it on.
  const [mentionActive, setMentionActive] = useState(0);
  const [mentionDismissed, setMentionDismissed] = useState<string | undefined>();
  const field = useRef<MarkdownFieldHandle>(null);
  const fieldRef = useCallback(
    (handle: MarkdownFieldHandle | null) => {
      field.current = handle;
      if (prompt) prompt.current = handle;
    },
    [prompt],
  );
  const pendingCaret = useRef<number | undefined>(undefined);
  const prompts = usePromptHistory(snapshot.rows);
  // Send becomes Stop in place once the turn starts; a second click of a
  // double-click, or a click right after Enter, must not cancel the new turn.
  const sentAt = useRef(0);
  /// What + wrote over the draft, so Escape can put the draft back.
  const plusDraft = useRef<{ written: string; original: string } | undefined>(undefined);
  const composing = useRef(false);
  // Send and Stop are separate buttons, so focus on Send moves to whichever replaces it.
  const refocusSend = useRef(false);
  /// The session id owns the prompt. A page can switch sessions without remounting the composer.
  const persistedSession = useRef(sessionId);
  const hydratedSession = useRef<string | undefined>(undefined);
  const restoringSession = useRef(false);
  /// Set while a switch runs and kept until the session change it brings (Lucas 2026-10-19).
  const carryPrompt = useRef(false);
  // Once a new chat has shown its location strip, keep its layout slot through the first send.
  // Resetting on a session key prevents a reopened chat from inheriting that reserved space.
  const locationSlotSession = useRef<string | undefined>(undefined);
  const locationSlotWasShown = useRef(false);
  const sendButton = useRef<HTMLButtonElement>(null);
  // The controls row swaps whole units as it narrows (composerRowFit.ts).
  const bar = useRef<HTMLDivElement>(null);
  useRowFit(bar);
  // The session's speed option, which the chips hand up: the bolt left of the mic (FastToggle.tsx).
  const [speed, setSpeed] = useState<SpeedTiers | undefined>(undefined);
  // Debug Settings' plain footer look (composerSettings.ts plainFooter, composerLocation.css).
  const { plainFooter } = useComposerSettings();
  /// Set while the host has not yet taken a prompt the composer still holds: Enter sends no copy.
  const sending = useRef(false);
  /// The newest submit, for the handle's `send` (rendered after the trust answer lands).
  const submitNow = useRef<(force: boolean) => boolean>(() => false);
  const allowImages = snapshot.summary?.promptCapabilities?.image !== false;
  // A paste on the prompt or the shell field, and a file drop anywhere (composer/attachmentIntake.tsx).
  const { attachments, setAttachments, attachError, setAttachError, dropping, attach } = useAttachmentIntake({
    allowImages,
    // A file pasted in shell mode is kept for the next prompt and uploads nothing; the mode stays.
    pasteTarget: (target) =>
      shellField.current?.contains(target)
        ? { uploads: false }
        : field.current?.element()?.contains(target)
          ? { uploads: true }
          : undefined,
    ...(upload ? { upload } : {}),
    insertPaths: (paths) => insertPaths(paths),
  });
  const attachmentsRef = useRef(attachments);
  attachmentsRef.current = attachments;
  // + then Attach files clicks this input: the system file chooser (an open panel in the app).
  const chooser = useRef<HTMLInputElement>(null);
  /// Puts machine paths at the caret, one per line.
  const insertPaths = (paths: string[]) => {
    const handle = field.current;
    if (!handle || paths.length === 0) return;
    const { value, selectionStart, selectionEnd } = handle.text();
    const before = value.slice(0, selectionStart);
    const inserted = (before && !before.endsWith("\n") && !before.endsWith(" ") ? " " : "") + paths.join("\n");
    const caret = before.length + inserted.length;
    handle.writeText(before + inserted + value.slice(selectionEnd), caret, caret);
  };
  useLayoutEffect(() => {
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
  useImperativeHandle(
    handle,
    () => ({
      restore(restoredText, restoredAttachments) {
        // What comes back goes first; what was typed or attached since stays after it.
        const typed = field.current?.value() ?? "";
        const next = typed.trim() ? `${restoredText}\n\n${typed}` : restoredText;
        if (field.current) field.current.type(next);
        else {
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
        setAttachments((current) => {
          const held = current.filter((chip) => chip.id !== attachment.id);
          return held.length >= MAX_ATTACHMENTS ? current : [...held, attachment];
        });
      },
      send: () => submitNow.current(true),
      focus: () => field.current?.focus(),
      wakeState: () => ({
        attachments: attachmentsRef.current.filter((chip) => !chip.shellRun),
        shell: shellRef.current.shell,
        shellText: shellRef.current.shellText,
      }),
      wake(state) {
        const back = state.attachments ?? [];
        if (back.length)
          setAttachments((current) =>
            [...back, ...current.filter((chip) => !back.some((kept) => kept.id === chip.id))].slice(0, MAX_ATTACHMENTS),
          );
        if (state.shell) {
          setShell(true);
          setShellText(state.shellText ?? "");
          shellCaret.current = state.shellText?.length ?? 0;
        }
      },
    }),
    [setAttachments],
  );
  useEffect(() => {
    // The prompt's DOM value is the typed text; a draft never replaces it.
    if (!draft || field.current?.value()) return;
    field.current?.reset(draft);
    setText((current) => seededText(current, draft));
    setCaret(draft.length);
    pendingCaret.current = draft.length;
  }, [draft]);
  useEffect(() => {
    if (switching) carryPrompt.current = true;
  }, [switching]);
  useEffect(() => {
    if (persistedSession.current === sessionId) return;
    // A switch's new session has no draft yet: the prompt typed before the pick moves to it.
    const carried = carryPrompt.current ? (field.current?.value() ?? text) : "";
    const previous = persistedSession.current;
    if (previous && hydratedSession.current === previous) writePersistedDraft(previous, field.current?.value() ?? text);
    persistedSession.current = sessionId;
    hydratedSession.current = undefined;
    restoringSession.current = true;
    const restored = readPersistedDraft(sessionId) ?? "";
    // A relaunch draft arrives with the handshake at the same time as the session reset. Keep it
    // when the local remount cache is empty; otherwise this effect can clear the host-provided
    // draft before the editor has initialized.
    // A chat's own saved draft wins: carried text only fills a session that has none, which a
    // switch's new session always is, so moving to another chat mid-switch keeps that chat's draft.
    const initial = restored || carried || draft || "";
    setText(initial);
    setCaret(initial.length);
    pendingCaret.current = initial.length;
  }, [sessionId, text, draft]);
  // After the session effect, so a switch that ends with its session change still carries.
  useEffect(() => {
    if (!switching) carryPrompt.current = false;
  }, [switching]);
  useEffect(() => {
    let current = true;
    void readDurableDraft(sessionId).then((restored) => {
      if (!current) return;
      const hasPendingWrite = hasPendingDraftWrite(sessionId);
      const currentText = field.current?.value() ?? textRef.current;
      if (!hasPendingWrite && restored && !currentText) {
        restoringSession.current = true;
        setText(restored);
        setCaret(restored.length);
        pendingCaret.current = restored.length;
      } else if (!hasPendingWrite && currentText.trim()) {
        // A local remount cache or keystroke arrived before the daemon read. Preserve it durably.
        writePersistedDraft(sessionId, currentText);
      }
      hydratedSession.current = sessionId;
      flushPendingDraftWrites();
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
    if (hydratedSession.current !== sessionId) return;
    writePersistedDraft(sessionId, text);
  }, [sessionId, text]);
  useEffect(() => {
    // Once the typing settles, so the host writes its file once per pause, not per keystroke.
    if (sessionId || !onUnsentDraft) return;
    const settled = setTimeout(() => onUnsentDraft(text), UNSENT_DRAFT_SETTLE_MS);
    return () => clearTimeout(settled);
  }, [sessionId, text, onUnsentDraft]);
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
  const query = slashQuery(text, caret);
  const open = query !== undefined && dismissed !== text && !recalling;
  const matches = useMemo(() => (open ? matchCommands(commands ?? [], query ?? "") : []), [commands, open, query]);

  useEffect(() => setActive(0), [query]);
  // Typing @ at a word start lists the chat's files that match what follows (cx-ncc.68).
  const mentionAt =
    !open && !recalling && searchFiles && mentionDismissed !== text
      ? mentionQuery(text, markdownOffset(text, caret))
      : undefined;
  const mentionState = useMentionSearch(searchFiles, mentionAt?.query);
  const mentionFiles = mentionResults(mentionState);
  const mentionSelected = Math.min(mentionActive, Math.max(mentionFiles.length - 1, 0));
  useEffect(() => setMentionActive(0), [mentionAt?.query]);
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
  };
  const pick = (command: SlashCommand) => {
    const next = applyCommand(text, caret, command);
    pendingCaret.current = next.caret;
    edit(next.text, next.caret);
    field.current?.focus();
  };
  /// The draft without what + wrote over it, while the text is still exactly that.
  const unwrapped = () => {
    const plus = plusDraft.current;
    return plus && plus.written === text ? plus.original : text;
  };
  /// Writes `@path ` over the `@word` being typed.
  const pickMention = (path: string) => {
    if (!mentionAt) return;
    const { markdown, shown } = mentionText(path);
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
    return send(false);
  };
  const send = (force: boolean, steer = false): boolean => {
    // acpmux refuses this chat on this connection (remoteEditing.ts): keep the draft.
    if (!remote.canSend) return false;
    // The folder's trust question is open: the prompt stays where it is.
    if (blocked && !force) return false;
    // The host has not taken the last prompt yet: it is still here, so Enter sends no copy.
    if (sending.current) return false;
    // The field holds markdown with its typed text escaped; the agent gets the text as typed.
    const draftText = unwrapped();
    const prompt = (field.current?.agentText(draftText) ?? draftText).trim();
    if (!prompt && attachments.length === 0) {
      plusDraft.current = undefined;
      return false;
    }
    // A Claude command that needs its terminal is not sent: the composer keeps it and says what to use.
    const cliOnly = attachments.length === 0 ? cliOnlyCommand(prompt, snapshot.summary?.harness) : undefined;
    if (cliOnly) {
      const values = { command: cliOnly.name };
      setAttachError(
        cliOnly.use === "access"
          ? t("composer.cliOnly.access", values)
          : cliOnly.use === "model"
            ? t("composer.cliOnly.model", values)
            : t("composer.cliOnly.terminal", values),
      );
      return false;
    }
    const owned = commands?.find(
      (command): command is CmuxCommand => command.source === "cmux" && commandArgs(prompt, command) !== undefined,
    );
    if (owned) {
      if (owned.name === "import") {
        if (!onImportFile) return false;
        importInput.current?.click();
      } else if (!onCmuxCommand) {
        return false;
      } else {
        const accepted = onCmuxCommand(owned, commandArgs(prompt, owned));
        if (accepted === false) return false;
      }
      setAttachments((current) => current.filter((attachment) => !attachments.includes(attachment)));
      setAttachError(undefined);
      plusDraft.current = undefined;
      edit("", 0);
      sentAt.current = Date.now();
      return true;
    }
    const fromSend = document.activeElement?.classList.contains("acpmux-send") ?? false;
    const sent = attachments;
    const taken = onSend(prompt, sent, steer);
    if (taken === false) return false;
    const written = field.current?.value() ?? "";
    const clear = (rest = "") => {
      setAttachments((current) => current.filter((attachment) => !sent.includes(attachment)));
      setAttachError(undefined);
      plusDraft.current = undefined;
      if (field.current && rest) field.current.type(rest);
      else edit(rest, rest.length);
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
  const stopTurn = () => {
    if (Date.now() - sentAt.current > STOP_GUARD_MS) onStop();
  };
  const keyDown = (event: KeyboardEvent) => {
    // Every key belongs to the input method while it composes, not only Enter.
    if (event.isComposing || event.keyCode === 229) return;
    if (interrupt(event)) return;
    const plain = !event.shiftKey && !event.altKey && !event.metaKey && !event.ctrlKey;
    // ⌘Return while a turn runs steers: the prompt goes in now instead of after the turn. (The
    // Quick Composer keeps its own ⌘Return and Esc, below.)
    const quick = Boolean(onOpenInWindow);
    const commandReturn =
      event.key === "Enter" && event.metaKey && !event.shiftKey && !event.altKey && !event.ctrlKey && !quick;
    if (commandReturn && steerable) {
      event.preventDefault();
      send(false, true);
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
      if (step && mentionFiles.length > 0) {
        event.preventDefault();
        setMentionActive((mentionSelected + step + mentionFiles.length) % mentionFiles.length);
        return;
      }
      if ((event.key === "Enter" || event.key === "Tab") && plain && mentionFiles[mentionSelected]) {
        event.preventDefault();
        pickMention(mentionFiles[mentionSelected].path);
        return;
      }
    }
    // ↑ on an empty prompt goes to the queue's last prompt (ComposerQueue.tsx has its keys).
    if (event.key === "ArrowUp" && plain && !open && !text.trim() && snapshot.queue.length) {
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
    // Esc on an empty prompt stops the turn, as Stop does.
    if (event.key === "Escape" && plain && !open && stop && !quick) {
      event.preventDefault();
      stopTurn();
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
      const typed = unwrapped().trim() !== "";
      const sent = submit(event);
      // A prompt the host refused stays in the composer, and the chat stays here.
      if (typed && !sent) return;
      onOpenInWindow(sent);
      return;
    }
    // Enter sends unless it picks a command: with the menu closed, with nothing
    // to pick (an unknown command or a pasted path), or on a command already
    // typed in full that takes no arguments.
    const typedInFull =
      matches[selected]?.command.name === query &&
      (!matches[selected]?.command.hint || matches[selected]?.command.source === "cmux");
    if (event.key === "Enter" && plain && (!open || matches.length === 0 || typedInFull)) {
      submit(event);
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

  const stop = !shell && snapshot.isWorking && !text.trim();
  // A prompt typed while a turn runs can go in now; an agent that cannot steer stops the turn.
  const steerable = !shell && snapshot.isWorking && remote.canSend && !blocked && Boolean(text.trim());
  const steerKind = snapshot.summary?.steering ? "steer" : "interrupt";
  // While a turn runs, what is sent waits behind it, so the empty prompt says so.
  const queues = !shell && snapshot.isWorking && remote.canSend && !blocked;
  // Mid-turn it teaches both keys, as Claude's composer does (Leo 2026-10-18): Return queues and
  // ⌘Return steers or interrupts. The Quick Composer's ⌘Return opens the window, and ⌘Return needs
  // typed text, so with only attachments staged it says just that Return queues.
  const placeholder = !queues
    ? COMPOSER_LABELS.placeholder
    : onOpenInWindow || attachments.length > 0
      ? COMPOSER_LABELS.placeholderQueued
      : steerKind === "steer"
        ? COMPOSER_LABELS.placeholderSteer
        : COMPOSER_LABELS.placeholderInterrupt;
  // Focus leaving the composer closes the menu and takes back what + wrote.
  const blur = (event: React.FocusEvent<HTMLFormElement>) => {
    if (event.currentTarget.contains(event.relatedTarget as Node | null)) return;
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
  const runEdit = (command: ComposerEditCommand) => {
    if (shell) shellField.current?.focus();
    else field.current?.focus();
    onEdit?.(command);
  };
  const fieldMenu: ContextMenuItem[] = [
    { id: "undo", label: t(COMPOSER_LABELS.undo), disabled: !fieldHistory.undo, onSelect: () => runField("undo") },
    { id: "redo", label: t(COMPOSER_LABELS.redo), disabled: !fieldHistory.redo, onSelect: () => runField("redo") },
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
    { id: "paste", label: t(COMPOSER_LABELS.paste), disabled: !onEdit, onSelect: () => runEdit("paste") },
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
  ];

  // The location strip: a tab on the card's top edge, its fill and edge the card's (hq#1957
  // composer location strip), so the card holds one controls row. Only a new chat has the visible
  // strip, before its first send (locationRow.ts): a started chat cannot change folder or machine.
  // Keep a non-painting slot for that strip while the first prompt changes the transcript. The
  // composer is bottom-anchored, so removing the slot in the same render would move every control
  // by the strip's height (cx-ncc.58); the slot is hidden when a queue is present, whose own height
  // becomes the top strip.
  const locationVisible = showsLocationRow(snapshot);
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
  const keepLocationSlot = !locationVisible && locationWasVisible && snapshot.queue.length === 0;
  const context = locationVisible ? (
    <ComposerContext
      projectChoices={projectChoices}
      onBrowseProject={onBrowseProject}
      onNewWorktree={onNewWorktree}
      onBrowseFolder={onBrowseFolder}
      onConnect={onConnect}
      summary={snapshot.summary}
      sessions={snapshot.sessions}
      peers={snapshot.peers}
      onProject={
        onProject &&
        ((cwd, peer) => {
          onProject(cwd, peer);
          field.current?.focus();
        })
      }
      localName={localName}
      onNewChat={onNewChat}
    />
  ) : keepLocationSlot ? (
    <div className="acpmux-composer-strip-placeholder" aria-hidden="true" />
  ) : null;
  return (
    <form
      ref={form}
      className="acpmux-composer"
      data-shell={shell ? "" : undefined}
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
      {!remote.note && blocked?.reason && (
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
        t={t}
        onRemove={onQueueRemove}
        onChange={onQueueChange}
        onLost={onQueueLost}
        onLeave={() => field.current?.focus()}
      />
      {context}
      <div className="acpmux-composer-box">
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
            if (file) void onImportFile?.(file);
          }}
        />
        {/* Anchored to the field, like the picker menus, so a queue above it never pushes the menu up. */}
        {open && (
          <SlashMenu
            matches={matches}
            active={selected}
            empty={!commands?.length ? t(COMPOSER_LABELS.noCommands) : t(COMPOSER_LABELS.noMatchingCommands)}
            onHover={setActive}
            onPick={pick}
          />
        )}
        {mentionAt && (
          <MentionMenu state={mentionState} active={mentionSelected} onHover={setMentionActive} onPick={pickMention} />
        )}
        <AttachmentStrip
          attachments={attachments}
          {...(attachError ? { error: attachError } : {})}
          dropping={dropping}
          codex={snapshot.summary?.family === "codex" || snapshot.summary?.harness === "codex"}
          onRemove={(id) => {
            setAttachments((current) => current.filter((item) => item.id !== id));
            field.current?.focus();
          }}
        />
        {/* The prompt's own right-click menu (POLISH.md right-click contract); WebKit's never shows. */}
        <ContextMenu className="acpmux-composer-field-menu" items={fieldMenu} selection="menu" onOpen={noteSelection}>
          {/* An editable prompt that drives a listbox: a native combobox cannot hold a multi-line prompt. */}
          <MarkdownField
            ref={fieldRef}
            className={shell ? "acpmux-composer-prompt is-hidden" : "acpmux-composer-prompt"}
            value={text}
            placeholder={t(placeholder)}
            attributes={{
              role: "combobox",
              "aria-label": t(COMPOSER_LABELS.prompt),
              "aria-multiline": "true",
              "aria-expanded": String(open || Boolean(mentionAt)),
              "aria-controls": open ? "acpmux-slash-menu" : mentionAt ? "acpmux-mention-menu" : undefined,
              "aria-autocomplete": "list",
              "aria-activedescendant":
                open && matches.length > 0
                  ? `acpmux-slash-${selected}`
                  : mentionAt && mentionFiles.length > 0
                    ? `acpmux-mention-${mentionSelected}`
                    : undefined,
            }}
            onBeforeInput={(data, state) => {
              // `!` first: shell mode, in place. A pasted `!cmd` keeps what follows the `!`.
              if (!onShell || state.composing || !state.empty || !data.startsWith("!")) return false;
              enterShell(data.slice(1));
              return true;
            }}
            onChange={(markdown, at) => edit(markdown, at)}
            onCaret={setCaret}
            onKeyDown={keyDown}
            onCompositionChange={(value) => {
              composing.current = value;
            }}
          />
          {shell && (
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
                spellCheck={false}
                autoCapitalize="off"
                autoCorrect="off"
                onChange={(event) => setShellText(event.target.value)}
                // ui-allow: the shell field's own editing keys (Enter runs, Esc or empty Backspace leaves, Ctrl-C stops).
                onKeyDown={shellKeyDown}
              />
            </div>
          )}
        </ContextMenu>
        {/* The button row: a right-click here shows a control hidden from its own (composerChrome.tsx). */}
        <ChromeArea className="acpmux-chrome-area" items={chrome.all}>
          <div ref={bar} className="acpmux-composer-bar" data-footer-look={plainFooter ? "plain" : undefined}>
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
                void attach(files);
              }}
            />
            {leading !== undefined ? (
              leading
            ) : (
              <Picker
                label={t(COMPOSER_LABELS.add)}
                className="acpmux-composer-plus"
                button={<PlusIcon />}
                align="start"
                returnFocus={false}
                sections={[
                  {
                    choices: [
                      { id: "attach", name: t(COMPOSER_LABELS.attach), icon: <PaperclipIcon /> },
                      // A harness without images would refuse the capture after the whole pick.
                      ...(capture && allowImages
                        ? [
                            {
                              id: "screenshot",
                              name: t(COMPOSER_LABELS.attachScreenshot),
                              icon: <Icon name="site.permission.camera" size={18} />,
                            },
                            {
                              id: "window",
                              name: t(COMPOSER_LABELS.attachWindow),
                              icon: <Icon name="site.permission.windowmanagement" size={18} />,
                            },
                          ]
                        : []),
                      { id: "mention", name: t(COMPOSER_LABELS.mention), icon: <AtIcon />, hint: "@" },
                      ...(searchFiles
                        ? [{ id: "files", name: t("files.search"), icon: <SearchIcon size={18} /> }]
                        : []),
                      ...(commands?.length
                        ? [
                            {
                              id: "commands",
                              name: t(COMPOSER_LABELS.commands),
                              icon: <SlashIcon />,
                              hint: "/",
                            },
                          ]
                        : []),
                      ...(planChoice ? [planChoice] : []),
                    ],
                    onPick: (id) =>
                      id.startsWith("plan:")
                        ? onMode?.(
                            planning ? (lastMode.current.mode ?? permissionModes[0]?.id ?? id.slice(5)) : id.slice(5),
                          )
                        : id === "attach"
                          ? chooser.current?.click()
                          : id === "screenshot" || id === "window"
                            ? // Back to the prompt either way (the + menu doesn't take focus back),
                              // unless the person moved focus out of the composer while the capture ran.
                              void capture?.(id === "window" ? "window" : "screen")
                                .then(async (shot) => {
                                  if (shot instanceof File) await attach([shot]);
                                  else if (shot) setAttachError(attachmentErrorText(shot, t));
                                })
                                .finally(() => {
                                  const focused = document.activeElement;
                                  if (!focused || focused === document.body || form.current?.contains(focused))
                                    field.current?.focus();
                                })
                            : id === "mention"
                              ? mention()
                              : id === "files"
                                ? setFindingFiles(true)
                                : openCommands(),
                  },
                ]}
              />
            )}
            {/* The granted-permission status gets no slot of its own in this row (hq#1957 item 15
                compact row): grants live in the permission mode's Access menu, one lock. */}
            {/* The chips hand up the speed option the bolt before the mic draws (FastToggle.tsx). */}
            <SpeedToggleHost.Provider value={setSpeed}>
              <Chips snapshot={snapshot} permissionAccess={permissionAccess} />
            </SpeedToggleHost.Provider>
            <span className="acpmux-composer-actions">
              {/* Steer comes in at the cluster's leading edge, so the mic and Send keep their places
                  when typing during a turn turns Stop into Steer and Send (hq#1957). */}
              {steerable && (
                <button
                  key="steer"
                  type="button"
                  className="acpmux-steer"
                  aria-label={t(steerKind === "steer" ? "composer.steerLabel" : "composer.interruptLabel")}
                  /* tooltip-allow: the button shows a verb; the tooltip says what it does and its shortcut */
                  title={t(steerKind === "steer" ? "composer.steerTooltip" : "composer.interruptTooltip")}
                  onClick={() => {
                    send(false, true);
                    field.current?.focus();
                  }}
                >
                  {t(steerKind === "steer" ? "composer.steer" : "composer.interrupt")}
                </button>
              )}
              {speed && <FastToggle speed={speed} />}
              {/* The mic leaves a narrow row (composerRowFit.ts micHidden). */}
              {accessory && (
                <span className="acpmux-fit-mic" data-fit-part="mic" data-fit-forms="full">
                  {accessory}
                </span>
              )}
              {stop ? (
                <button
                  key="stop"
                  ref={sendButton}
                  type="button"
                  className="acpmux-send acpmux-cancel"
                  aria-label={t(COMPOSER_LABELS.stop)}
                  title={t(COMPOSER_LABELS.stop)}
                  onClick={stopTurn}
                >
                  <StopIcon />
                </button>
              ) : remote.canSend ? (
                <button
                  key="send"
                  ref={sendButton}
                  type="submit"
                  disabled={Boolean(blocked) && !shell}
                  className={`acpmux-send${(shell ? shellText.trim() : !blocked && (text.trim() || attachments.length)) ? " acpmux-send-ready" : ""}`}
                  aria-label={shell ? t("composer.shellRun") : t(COMPOSER_LABELS.send)}
                  title={
                    shell
                      ? t("composer.shellRun")
                      : blocked?.reason
                        ? t(blocked.reason)
                        : t(snapshot.isWorking ? "composer.queueTooltip" : "composer.sendTooltip")
                  }
                >
                  <ArrowUpIcon />
                </button>
              ) : null}
            </span>
          </div>
        </ChromeArea>
      </div>
    </form>
  );
}

/// One attachment above the prompt. An image draws a thumbnail in its own shape and opens in the chat's image
/// viewer on a click; one the pane cannot draw falls back to its name, never an empty square.
function SlashMenu({
  matches,
  active,
  empty,
  onHover,
  onPick,
}: {
  matches: SlashMatch[];
  active: number;
  empty: string;
  onHover(index: number): void;
  onPick(command: SlashCommand): void;
}) {
  const t = useT();
  const list = useRef<HTMLDivElement>(null);
  // Above the composer, or past the window's edge when the pane has no room there (cx-6k6cg).
  const escape = useEscapingList("top", 6);
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
        className="ui-popup acpmux-slash-menu acpmux-slash-empty"
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
      className="ui-popup acpmux-slash-menu"
      id="acpmux-slash-menu"
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
      role="listbox"
      aria-label={t(COMPOSER_LABELS.commands)}
    >
      {/* Virtual focus: the prompt keeps focus and names the row through aria-activedescendant. */}
      {matches.map((match, index) => (
        <div
          key={match.command.name}
          id={`acpmux-slash-${index}`}
          // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
          role="option"
          tabIndex={-1}
          aria-selected={index === active}
          className={index === active ? "acpmux-slash-row acpmux-slash-active" : "acpmux-slash-row"}
          onMouseMove={() => {
            if (index !== active) onHover(index);
          }}
          onMouseDown={(event) => {
            event.preventDefault();
            onPick(match.command);
          }}
        >
          <span className="acpmux-slash-name">
            /<Highlighted name={match.command.name} ranges={match.ranges} />
          </span>
          {match.command.hint && <span className="acpmux-slash-hint">{match.command.hint}</span>}
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
            {match.command.descriptionKey ? t(match.command.descriptionKey) : match.command.description}
          </span>
        </div>
      ))}
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

/// Where the caret, counted in the characters the prompt shows, falls in its markdown: a
/// backslash escape and a character reference (the serializer's `&#x20;`) each show as one.
function markdownOffset(markdown: string, shown: number): number {
  let index = 0;
  for (let count = 0; count < shown && index < markdown.length; count++) {
    const escape = /^(\\[!-/:-@[-`{-~]|&(#x[0-9a-f]+|#[0-9]+|[a-z][a-z0-9]*);)/i.exec(markdown.slice(index));
    index += escape ? escape[0].length : 1;
  }
  return index;
}
