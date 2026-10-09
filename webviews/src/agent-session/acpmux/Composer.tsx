import React, { useCallback, useEffect, useImperativeHandle, useLayoutEffect, useMemo, useRef, useState } from "react";
import { createPortal } from "react-dom";
import type { AcpmuxSnapshot } from "./model";
import { dragHasFiles, filesFrom, readAttachments, type AttachmentError, type ComposerAttachment } from "./attachments";
import { cappedShellChips, shellAttachment, type ShellRun } from "./shell/shellRuns";
import { type ChatMove, moveAttachment } from "./shell/chatMoves";
import type { Project } from "./ProjectChooser";
import { ComposerContext } from "./ComposerContext";
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
} from "./ComposerPickers";
import { FileSearch } from "./FileSearch";
import type { Choice } from "./ComposerPickers";
import type { FileSearchSource } from "./fileSearchModel";
import { commandArgs, type CmuxCommand } from "./cmuxCommands";
import { applyCommand, matchCommands, slashQuery, type SlashCommand, type SlashMatch } from "./slashCommands";
import {
  readDurableDraft,
  readPersistedDraft,
  seededText,
  useDraftActionsVersion,
  writePersistedDraft,
} from "./composerDraft";
import { MarkdownField, type MarkdownFieldHandle } from "./MarkdownField";
import { type StringKey, type Translate, useT } from "./i18n";
import { remoteComposer } from "./remoteEditing";
import type { SendBlock } from "./useFolderTrustAsk";

/// Composer copy. English defaults until the host passes localized labels, as the rest of the pane does today.
/// How long after a send the Stop button that replaces Send ignores clicks.
const STOP_GUARD_MS = 600;

export const COMPOSER_LABELS = {
  placeholder: "composer.placeholder",
  add: "composer.add",
  mention: "composer.mention",
  attach: "composer.attach",
  prompt: "composer.prompt",
  send: "composer.send",
  stop: "composer.stop",
  commands: "composer.commands",
  noCommands: "composer.noCommands",
  noMatchingCommands: "composer.noMatchingCommands",
  attachments: "composer.attachments",
  removeAttachment: "composer.removeAttachment",
  dropFiles: "composer.dropFiles",
  tooLarge: "composer.tooLarge",
  unsupported: "composer.unsupported",
  imagesUnsupported: "composer.imagesUnsupported",
  tooMany: "composer.tooMany",
  queue: "composer.queue",
  queued: "composer.queued",
} as const satisfies Record<string, StringKey>;

function attachmentErrorText(error: AttachmentError, t: Translate): string {
  return t(COMPOSER_LABELS[error.reason], { name: error.name });
}

/// What the pane can do to the composer from outside it.
export type ComposerHandle = {
  /// Puts a held-back prompt in: `text` before what is typed now, `attachments` before the rest.
  restore(text: string, attachments: ComposerAttachment[]): void;
  /// Sends what is typed now, as Enter would, even while `blocked` is still drawn (the user just
  /// answered Trust for the prompt the composer held). False when nothing went.
  send(): boolean;
};

type Props = {
  snapshot: AcpmuxSnapshot;
  chips: React.ComponentType<{ snapshot: AcpmuxSnapshot }>;
  /// Sends a prompt. False when nothing can take it yet (no acpmux), so the prompt keeps it. A
  /// promise holds the prompt in the composer until the host takes it: it clears when the promise
  /// resolves and stays (for the user to send again) when it rejects, so a refusal loses nothing.
  onSend(text: string, attachments?: ComposerAttachment[]): boolean | void | Promise<unknown>;
  onStop(): void;
  /// Text the prompt starts with, such as what a chat opened from another tab inherited.
  /// Each new value fills an empty prompt once, caret at the end; it is never sent by itself.
  draft?: string;
  /// The durable session whose unsent prompt belongs in this composer.
  sessionId?: string;
  /// The bar's left button, such as attach; by default + opens the agent's commands. `null` leaves the slot empty.
  leading?: React.ReactNode;
  /// Buttons before Send, such as the dictation mic.
  accessory?: React.ReactNode;
  /// Also receives the prompt field's handle, for dictation, which writes into it as typing does.
  prompt?: React.RefObject<MarkdownFieldHandle | null>;
  /// Receives the composer's handle, which puts a prompt a harness switch held back (its text
  /// and attachments) into the composer.
  handle?: React.Ref<ComposerHandle>;
  /// Opens the host's file and image picker; the + menu offers it only when set.
  onAttach?(): void;
  /// Handles a cmux-owned slash command after the user submits it.
  onCmuxCommand?(command: CmuxCommand, args?: string): boolean | void;
  /// Reads a transcript chosen by the cmux-owned `/import` command.
  onImportFile?(file: File): void | Promise<void>;
  /// Searches the session's files; the + menu offers Search files only when set.
  searchFiles?: FileSearchSource;
  /// Starts a new chat in another project; the tray's project pill chooses only when set.
  onProject?(cwd: string, peer?: string): void;
  projectChoices?: Project[];
  onBrowseProject?(): void;
  /// The location row's SSH… and cmux Cloud… rows open the host's connect flows.
  onConnect?(kind: "ssh" | "cloud"): void;
  /// This Mac's name for the location row.
  localName?: string;
  /// The folder a started chat moved to (shell/chatMoves.ts).
  movedTo?: string;
  /// Moves a started chat to another folder; the next prompt carries the move as a `cd` chip.
  onMove?(cwd: string): ChatMove;
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
  draft,
  leading,
  accessory,
  prompt,
  onAttach,
  onCmuxCommand,
  onImportFile,
  searchFiles,
  onProject,
  projectChoices,
  onBrowseProject,
  onConnect,
  localName,
  movedTo,
  onMove,
  onShell,
  onShellInterrupt,
  onMode,
  onOpenInWindow,
  handle,
  sessionId,
  blocked,
}: Props) {
  const t = useT();
  // The native action map is replaced on reconnect while the session stays the same. Subscribe
  // so a durable read retries as soon as that map is available again.
  const draftActionsVersion = useDraftActionsVersion();
  const [findingFiles, setFindingFiles] = useState(false);
  // A new folder (another chat) closes the palette, so no row from the last one stays pickable.
  useEffect(() => setFindingFiles(false), [searchFiles]);
  // Search files sits over the transcript, so it mounts in the composer's parent (the pane's
  // main column), not inside the composer the slash menu anchors to.
  const form = useRef<HTMLFormElement>(null);
  const importInput = useRef<HTMLInputElement>(null);
  const [text, setText] = useState(() => readPersistedDraft(sessionId) ?? "");
  const textRef = useRef(text);
  textRef.current = text;
  /// Shell mode: the prompt is a plain monospace field whose Enter runs a command. The markdown
  /// prompt stays mounted under it, keeping its own draft.
  const [shell, setShell] = useState(false);
  const [shellText, setShellText] = useState("");
  const shellField = useRef<HTMLTextAreaElement>(null);
  const shellCaret = useRef<number | undefined>(undefined);
  const [caret, setCaret] = useState(0);
  const [active, setActive] = useState(0);
  const [dismissed, setDismissed] = useState<string | undefined>();
  const [attachments, setAttachments] = useState<ComposerAttachment[]>([]);
  const [attachError, setAttachError] = useState<string | undefined>();
  const [dropping, setDropping] = useState(false);
  const field = useRef<MarkdownFieldHandle>(null);
  const fieldRef = useCallback(
    (handle: MarkdownFieldHandle | null) => {
      field.current = handle;
      if (prompt) prompt.current = handle;
    },
    [prompt],
  );
  const pendingCaret = useRef<number | undefined>(undefined);
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
  const restoringSession = useRef(false);
  const sendButton = useRef<HTMLButtonElement>(null);
  /// Set while the host has not yet taken a prompt the composer still holds: Enter sends no copy.
  const sending = useRef(false);
  /// The newest submit, for the handle's `send` (rendered after the trust answer lands).
  const submitNow = useRef<(force: boolean) => boolean>(() => false);
  const held = useRef(0);
  held.current = attachments.length;
  const allowImages = snapshot.summary?.promptCapabilities?.image !== false;
  const attach = useRef<(files: File[]) => Promise<void>>(async () => {});
  attach.current = async (files: File[]) => {
    if (files.length === 0) return;
    const read = await readAttachments(files, held.current, allowImages);
    setAttachments((current) => [...current, ...read.attachments]);
    setAttachError(read.errors[0] ? attachmentErrorText(read.errors[0], t) : undefined);
  };
  useEffect(() => {
    const over = (event: DragEvent) => {
      if (!dragHasFiles(event.dataTransfer)) return;
      event.preventDefault();
      setDropping(true);
    };
    const leave = (event: DragEvent) => {
      if (!event.relatedTarget) setDropping(false);
    };
    const drop = (event: DragEvent) => {
      if (!dragHasFiles(event.dataTransfer)) return;
      event.preventDefault();
      setDropping(false);
      void attach.current(filesFrom(event.dataTransfer));
    };
    const paste = (event: ClipboardEvent) => {
      const target = event.target as Node;
      // A file pasted in shell mode is kept for the next prompt; the mode stays.
      if (!field.current?.element()?.contains(target) && !shellField.current?.contains(target)) return;
      const files = filesFrom(event.clipboardData);
      if (files.length === 0) return;
      event.preventDefault();
      void attach.current(files);
    };
    document.addEventListener("dragover", over);
    document.addEventListener("dragleave", leave);
    document.addEventListener("drop", drop);
    document.addEventListener("paste", paste);
    return () => {
      document.removeEventListener("dragover", over);
      document.removeEventListener("dragleave", leave);
      document.removeEventListener("drop", drop);
      document.removeEventListener("paste", paste);
    };
  }, []);
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
      send: () => submitNow.current(true),
    }),
    [],
  );
  useEffect(() => {
    // The prompt's DOM value is the typed text; a draft never replaces it.
    if (!draft || field.current?.value()) return;
    setText((current) => seededText(current, draft));
    setCaret(draft.length);
    pendingCaret.current = draft.length;
  }, [draft]);
  useEffect(() => {
    if (persistedSession.current === sessionId) return;
    const previous = persistedSession.current;
    if (previous) writePersistedDraft(previous, field.current?.value() ?? text);
    persistedSession.current = sessionId;
    restoringSession.current = true;
    const restored = readPersistedDraft(sessionId) ?? "";
    setText(restored);
    setCaret(restored.length);
    pendingCaret.current = restored.length;
  }, [sessionId, text]);
  useEffect(() => {
    let current = true;
    void readDurableDraft(sessionId).then((restored) => {
      if (!current || !restored || field.current?.value() || textRef.current) return;
      setText(restored);
      setCaret(restored.length);
      pendingCaret.current = restored.length;
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
    writePersistedDraft(sessionId, text);
  }, [sessionId, text]);
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
      ? { id: `plan:${plan.id}`, name: planning ? "Build" : "Plan", icon: planning ? <BuildIcon /> : <PlanIcon /> }
      : undefined;
  const query = slashQuery(text, caret);
  const open = query !== undefined && dismissed !== text;
  const matches = useMemo(() => (open ? matchCommands(commands ?? [], query ?? "") : []), [commands, open, query]);

  useEffect(() => setActive(0), [query]);
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
  /// Sends the draft; false when there was nothing to send or the host refused it.
  const submit = (event: { preventDefault(): void }): boolean => {
    event.preventDefault();
    return send(false);
  };
  const send = (force: boolean): boolean => {
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
    const taken = onSend(prompt, sent);
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
    if (event.key === "ArrowDown" || event.key === "ArrowUp") {
      event.preventDefault();
      const step = event.key === "ArrowDown" ? 1 : -1;
      setActive((selected + step + matches.length) % matches.length);
    } else if ((event.key === "Enter" || event.key === "Tab") && plain) {
      event.preventDefault();
      pick(matches[selected].command);
    }
  };

  const stop = !shell && snapshot.isWorking && !text.trim();
  // Focus leaving the composer closes the menu and takes back what + wrote.
  const blur = (event: React.FocusEvent<HTMLFormElement>) => {
    if (event.currentTarget.contains(event.relatedTarget as Node | null)) return;
    const original = unwrapped();
    plusDraft.current = undefined;
    if (original !== text) edit(original, original.length);
    else if (open) setDismissed(text);
  };
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
    >
      {snapshot.queue.length > 0 && (
        <ol className="acpmux-composer-queue" aria-label={t(COMPOSER_LABELS.queue)}>
          {snapshot.queue.map((entry) => (
            <li className="acpmux-queued" key={entry.id} title={entry.prompt}>
              <span className="acpmux-queued-label" aria-hidden="true">
                {t(COMPOSER_LABELS.queued)}
              </span>
              <span className="acpmux-queued-text">{entry.prompt}</span>
            </li>
          ))}
        </ol>
      )}
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
        {(attachments.length > 0 || attachError || dropping) && (
          <fieldset className="acpmux-attachments" aria-label={t(COMPOSER_LABELS.attachments)}>
            {attachments.map((attachment) => (
              <AttachmentChip
                key={attachment.id}
                attachment={attachment}
                onRemove={(id) => {
                  setAttachments((current) => current.filter((item) => item.id !== id));
                  field.current?.focus();
                }}
              />
            ))}
            {dropping ? (
              <span className="acpmux-attachment-note">{t(COMPOSER_LABELS.dropFiles)}</span>
            ) : (
              attachError && <output className="acpmux-attachment-note">{attachError}</output>
            )}
          </fieldset>
        )}
        {/* An editable prompt that drives a listbox: a native combobox cannot hold a multi-line prompt. */}
        <MarkdownField
          ref={fieldRef}
          className={shell ? "acpmux-composer-prompt is-hidden" : "acpmux-composer-prompt"}
          value={text}
          placeholder={t(COMPOSER_LABELS.placeholder)}
          attributes={{
            role: "combobox",
            "aria-label": t(COMPOSER_LABELS.prompt),
            "aria-multiline": "true",
            "aria-expanded": String(open),
            "aria-controls": open ? "acpmux-slash-menu" : undefined,
            "aria-autocomplete": "list",
            "aria-activedescendant": open && matches.length > 0 ? `acpmux-slash-${selected}` : undefined,
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
        <div className="acpmux-composer-bar">
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
                    ...(onAttach ? [{ id: "attach", name: t(COMPOSER_LABELS.attach), icon: <PaperclipIcon /> }] : []),
                    { id: "mention", name: t(COMPOSER_LABELS.mention), icon: <AtIcon />, hint: "@" },
                    ...(searchFiles ? [{ id: "files", name: t("files.search"), icon: <SearchIcon size={18} /> }] : []),
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
                        ? onAttach?.()
                        : id === "mention"
                          ? mention()
                          : id === "files"
                            ? setFindingFiles(true)
                            : openCommands(),
                },
              ]}
            />
          )}
          <Chips snapshot={snapshot} />
          <span className="acpmux-composer-actions">
            {accessory}
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
                title={shell ? t("composer.shellRun") : blocked?.reason ? t(blocked.reason) : t("composer.sendTooltip")}
              >
                <ArrowUpIcon />
              </button>
            ) : null}
          </span>
        </div>
        {/* The location row is the card's footer: one fill, one edge, a hairline above it. */}
        <ComposerContext
          projectChoices={projectChoices}
          onBrowseProject={onBrowseProject}
          onConnect={onConnect}
          summary={snapshot.summary}
          sessions={snapshot.sessions}
          peers={snapshot.peers}
          started={(snapshot.summary?.turnCount ?? 0) > 0 || snapshot.rows.length > 0}
          onProject={
            onProject &&
            ((cwd, peer) => {
              onProject(cwd, peer);
              field.current?.focus();
            })
          }
          localName={localName}
          movedTo={movedTo}
          busy={snapshot.isWorking}
          onMove={
            onMove &&
            ((cwd) => {
              const move = onMove(cwd);
              setAttachments((current) => [...current.filter((item) => !item.move), moveAttachment(move)]);
              field.current?.focus();
            })
          }
        />
      </div>
    </form>
  );
}

function AttachmentChip({ attachment, onRemove }: { attachment: ComposerAttachment; onRemove(id: string): void }) {
  const t = useT();
  const remove = (
    <button
      type="button"
      className="acpmux-attachment-remove"
      aria-label={t(COMPOSER_LABELS.removeAttachment, { name: attachment.name })}
      onClick={() => onRemove(attachment.id)}
    >
      ×
    </button>
  );
  if (attachment.kind === "image")
    return (
      <div className="acpmux-attachment acpmux-attachment-image" title={attachment.name}>
        <img alt={attachment.name} src={`data:${attachment.mimeType};base64,${attachment.data}`} />
        {remove}
      </div>
    );
  return (
    <div className="acpmux-attachment acpmux-attachment-file" title={attachment.name}>
      <span>{attachment.name}</span>
      {remove}
    </div>
  );
}

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
  useLayoutEffect(() => {
    list.current?.querySelector<HTMLElement>(`#acpmux-slash-${active}`)?.scrollIntoView?.({ block: "nearest" });
  }, [active]);
  // A native select or datalist cannot hold the matched-name bolding and descriptions.
  if (matches.length === 0)
    return (
      <div
        className="acpmux-slash-menu acpmux-slash-empty"
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
      ref={list}
      className="acpmux-slash-menu"
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
          {match.command.source && <span className="acpmux-slash-source">{match.command.source}</span>}
          <span className="acpmux-slash-description">{match.command.description}</span>
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
