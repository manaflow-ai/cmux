import React, { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import { createPortal } from "react-dom";
import type { AcpmuxSnapshot } from "./model";
import {
  dragHasFiles,
  filesFrom,
  readAttachments,
  type AttachmentError,
  type ComposerAttachment,
} from "./attachments";
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
  ShieldIcon,
  SlashIcon,
  StopIcon,
} from "./ComposerPickers";
import { FileSearch } from "./FileSearch";
import type { Choice } from "./ComposerPickers";
import type { FileSearchSource } from "./fileSearchModel";
import {
  applyCommand,
  matchCommands,
  slashQuery,
  type SlashCommand,
  type SlashMatch,
} from "./slashCommands";
import { seededText } from "./composerDraft";
import { MarkdownField, type MarkdownFieldHandle } from "./MarkdownField";
import { t } from "./i18n";

/// Composer copy. English defaults until the host passes localized labels, as the rest of the pane does today.
/// How long after a send the Stop button that replaces Send ignores clicks.
const STOP_GUARD_MS = 600;

export const COMPOSER_LABELS = {
  placeholder: "Do anything",
  add: "Add",
  mention: "Mention a file or folder",
  attach: "Attach files or images",
  prompt: "Prompt",
  send: "Send",
  stop: "Stop",
  commands: "Commands",
  noCommands: "No commands",
  noMatchingCommands: "No matching commands",
  attachments: "Attachments",
  removeAttachment: "Remove {name}",
  dropFiles: "Drop images or text files to attach",
  tooLarge: "{name} is too large to attach",
  unsupported: "{name} is not an image or a text file",
  imagesUnsupported: "This agent does not take images",
  tooMany: "Up to 10 attachments per message",
  queue: "Queued prompts",
  queued: "Queued",
};

function attachmentErrorText(error: AttachmentError): string {
  return COMPOSER_LABELS[error.reason].replace("{name}", error.name);
}

type Props = {
  snapshot: AcpmuxSnapshot;
  chips: React.ComponentType<{ snapshot: AcpmuxSnapshot }>;
  /// Sends a prompt. False when nothing can take it yet (no acpmux), so the prompt keeps it.
  onSend(text: string, attachments?: ComposerAttachment[]): boolean | void;
  onStop(): void;
  /// Text the prompt starts with, such as what a chat opened from another tab inherited.
  /// Each new value fills an empty prompt once, caret at the end; it is never sent by itself.
  draft?: string;
  /// The bar's left button, such as attach; by default + opens the agent's commands. `null` leaves the slot empty.
  leading?: React.ReactNode;
  /// Buttons before Send, such as the dictation mic.
  accessory?: React.ReactNode;
  /// Also receives the prompt field's handle, for dictation, which writes into it as typing does.
  prompt?: React.RefObject<MarkdownFieldHandle | null>;
  /// Opens the host's file and image picker; the + menu offers it only when set.
  onAttach?(): void;
  /// Searches the session's files; the + menu offers Search files only when set.
  searchFiles?: FileSearchSource;
  /// Starts a new chat in another project; the tray's project pill chooses only when set.
  onProject?(cwd: string, peer?: string): void;
  /// Changes the approval mode from the + menu while keeping the keyboard shortcut path intact.
  onMode?(modeId: string): void;
  /// ⌘Return, only where set (the Quick Composer): sends what was typed as Return would, then
  /// asks to open the chat in a window. `sent` says whether there was a prompt to send.
  onOpenInWindow?(sent: boolean): void;
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
  searchFiles,
  onProject,
  onMode,
  onOpenInWindow,
}: Props) {
  const [findingFiles, setFindingFiles] = useState(false);
  // A new folder (another chat) closes the palette, so no row from the last one stays pickable.
  useEffect(() => setFindingFiles(false), [searchFiles]);
  // Search files sits over the transcript, so it mounts in the composer's parent (the pane's
  // main column), not inside the composer the slash menu anchors to.
  const form = useRef<HTMLFormElement>(null);
  const [text, setText] = useState("");
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
  const sendButton = useRef<HTMLButtonElement>(null);
  const held = useRef(0);
  held.current = attachments.length;
  const allowImages = snapshot.summary?.promptCapabilities?.image !== false;
  const attach = useRef<(files: File[]) => Promise<void>>(async () => {});
  attach.current = async (files: File[]) => {
    if (files.length === 0) return;
    const read = await readAttachments(files, held.current, allowImages);
    setAttachments((current) => [...current, ...read.attachments]);
    setAttachError(read.errors[0] ? attachmentErrorText(read.errors[0]) : undefined);
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
      if (!field.current?.element()?.contains(event.target as Node)) return;
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
  useEffect(() => {
    // The prompt's DOM value is the typed text; a draft never replaces it.
    if (!draft || field.current?.value()) return;
    setText((current) => seededText(current, draft));
    setCaret(draft.length);
    pendingCaret.current = draft.length;
  }, [draft]);
  const commands = snapshot.commands;
  const modeChoices: Choice[] = (snapshot.summary?.modes?.availableModes ?? [])
    .filter((mode) => !/(^|[-_])plan$/i.test(mode.id))
    .map((mode) => ({
      id: `mode:${mode.id}`,
      name: mode.name || mode.id,
      description: mode.description,
      icon: <ShieldIcon />,
    }));
  const plan = snapshot.summary?.modes?.availableModes?.find((mode) =>
    /(^|[-_])plan$/i.test(mode.id),
  );
  const currentModeId = snapshot.summary?.modes?.currentModeId;
  const lastMode = useRef<{ sessionId?: string; mode?: string }>({});
  if (lastMode.current.sessionId !== snapshot.summary?.sessionId) {
    lastMode.current = { sessionId: snapshot.summary?.sessionId };
  }
  if (currentModeId && !/(^|[-_])plan$/i.test(currentModeId)) lastMode.current.mode = currentModeId;
  const planning = plan?.id === currentModeId;
  const modePlanChoices: Choice[] = [
    ...modeChoices,
    ...(plan
      ? [
          {
            id: `plan:${plan.id}`,
            name: planning ? "Build" : "Plan",
            icon: planning ? <BuildIcon /> : <PlanIcon />,
          },
        ]
      : []),
  ];
  const query = slashQuery(text, caret);
  const open = query !== undefined && dismissed !== text;
  const matches = useMemo(
    () => (open ? matchCommands(commands ?? [], query ?? "") : []),
    [commands, open, query],
  );

  useEffect(() => setActive(0), [query]);
  // A live command update can shrink the list under the selection.
  const selected = Math.min(active, Math.max(matches.length - 1, 0));
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
    const prompt = unwrapped().trim();
    if (!prompt && attachments.length === 0) {
      plusDraft.current = undefined;
      return false;
    }
    const fromSend = document.activeElement?.classList.contains("acpmux-send") ?? false;
    if (onSend(prompt, attachments) === false) return false;
    setAttachments([]);
    setAttachError(undefined);
    plusDraft.current = undefined;
    edit("", 0);
    sentAt.current = Date.now();
    refocusSend.current = fromSend;
    return true;
  };
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
    const named =
      first !== undefined && (commands ?? []).some((command) => command.name.startsWith(first));
    const next = named ? text : text ? `/ ${text}` : "/";
    plusDraft.current = { written: next, original: text };
    pendingCaret.current = 1;
    edit(next, 1);
    field.current?.focus();
  };
  const stopTurn = () => {
    if (Date.now() - sentAt.current > STOP_GUARD_MS) onStop();
  };
  const keyDown = (event: KeyboardEvent) => {
    // Every key belongs to the input method while it composes, not only Enter.
    if (event.isComposing || event.keyCode === 229) return;
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
      matches[selected]?.command.name === query && !matches[selected]?.command.hint;
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

  const stop = snapshot.isWorking && !text.trim();
  // Focus leaving the composer closes the menu and takes back what + wrote.
  const blur = (event: React.FocusEvent<HTMLFormElement>) => {
    if (event.currentTarget.contains(event.relatedTarget as Node | null)) return;
    const original = unwrapped();
    plusDraft.current = undefined;
    if (original !== text) edit(original, original.length);
    else if (open) setDismissed(text);
  };
  return (
    <form ref={form} className="acpmux-composer" onSubmit={submit} onBlur={blur}>
      {snapshot.queue.length > 0 && (
        <ol className="acpmux-composer-queue" aria-label={COMPOSER_LABELS.queue}>
          {snapshot.queue.map((entry) => (
            <li className="acpmux-queued" key={entry.id} title={entry.prompt}>
              <span className="acpmux-queued-label" aria-hidden="true">
                {COMPOSER_LABELS.queued}
              </span>
              <span className="acpmux-queued-text">{entry.prompt}</span>
            </li>
          ))}
        </ol>
      )}
      <ComposerContext
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
      />
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
        {/* Anchored to the field, like the picker menus, so a queue above it never pushes the menu up. */}
        {open && (
          <SlashMenu
            matches={matches}
            active={selected}
            empty={
              !commands?.length ? COMPOSER_LABELS.noCommands : COMPOSER_LABELS.noMatchingCommands
            }
            onHover={setActive}
            onPick={pick}
          />
        )}
        {(attachments.length > 0 || attachError || dropping) && (
          <fieldset className="acpmux-attachments" aria-label={COMPOSER_LABELS.attachments}>
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
              <span className="acpmux-attachment-note">{COMPOSER_LABELS.dropFiles}</span>
            ) : (
              attachError && <output className="acpmux-attachment-note">{attachError}</output>
            )}
          </fieldset>
        )}
        {/* An editable prompt that drives a listbox: a native combobox cannot hold a multi-line prompt. */}
        <MarkdownField
          ref={fieldRef}
          className="acpmux-composer-prompt"
          value={text}
          placeholder={COMPOSER_LABELS.placeholder}
          attributes={{
            role: "combobox",
            "aria-label": COMPOSER_LABELS.prompt,
            "aria-multiline": "true",
            "aria-expanded": String(open),
            "aria-controls": open ? "acpmux-slash-menu" : undefined,
            "aria-autocomplete": "list",
            "aria-activedescendant":
              open && matches.length > 0 ? `acpmux-slash-${selected}` : undefined,
          }}
          onChange={(markdown, at) => edit(markdown, at)}
          onCaret={setCaret}
          onKeyDown={keyDown}
          onCompositionChange={(value) => {
            composing.current = value;
          }}
        />
        <div className="acpmux-composer-bar">
          {leading !== undefined ? (
            leading
          ) : (
            <Picker
              label={COMPOSER_LABELS.add}
              className="acpmux-composer-plus"
              button={<PlusIcon />}
              align="start"
              returnFocus={false}
              sections={[
                ...(modePlanChoices.length > 0 && onMode
                  ? [
                      {
                        title: "Mode",
                        choices: modePlanChoices,
                        onPick: (id: string) => {
                          if (id.startsWith("mode:")) onMode(id.slice("mode:".length));
                          else if (id.startsWith("plan:"))
                            onMode(
                              planning
                                ? (lastMode.current.mode ??
                                    modeChoices[0]?.id?.slice(5) ??
                                    id.slice(5))
                                : id.slice(5),
                            );
                        },
                      },
                    ]
                  : []),
                {
                  choices: [
                    ...(onAttach
                      ? [{ id: "attach", name: COMPOSER_LABELS.attach, icon: <PaperclipIcon /> }]
                      : []),
                    { id: "mention", name: COMPOSER_LABELS.mention, icon: <AtIcon />, hint: "@" },
                    ...(searchFiles
                      ? [{ id: "files", name: t("files.search"), icon: <SearchIcon size={18} /> }]
                      : []),
                    ...(commands?.length
                      ? [
                          {
                            id: "commands",
                            name: COMPOSER_LABELS.commands,
                            icon: <SlashIcon />,
                            hint: "/",
                          },
                        ]
                      : []),
                  ],
                  onPick: (id) =>
                    id === "attach"
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
          <span className="acpmux-separator" aria-hidden="true" />
          <Chips snapshot={snapshot} />
          <span className="acpmux-composer-actions">
            {accessory}
            {stop ? (
              <button
                key="stop"
                ref={sendButton}
                type="button"
                className="acpmux-send acpmux-cancel"
                aria-label={COMPOSER_LABELS.stop}
                title={COMPOSER_LABELS.stop}
                onClick={stopTurn}
              >
                <StopIcon />
              </button>
            ) : (
              <button
                key="send"
                ref={sendButton}
                type="submit"
                className={`acpmux-send${text.trim() || attachments.length ? " acpmux-send-ready" : ""}`}
                aria-label={COMPOSER_LABELS.send}
                title={t("composer.sendTooltip")}
              >
                <ArrowUpIcon />
              </button>
            )}
          </span>
        </div>
      </div>
    </form>
  );
}

function AttachmentChip({
  attachment,
  onRemove,
}: {
  attachment: ComposerAttachment;
  onRemove(id: string): void;
}) {
  const remove = (
    <button
      type="button"
      className="acpmux-attachment-remove"
      aria-label={COMPOSER_LABELS.removeAttachment.replace("{name}", attachment.name)}
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
  const list = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    list.current
      ?.querySelector<HTMLElement>(`#acpmux-slash-${active}`)
      ?.scrollIntoView?.({ block: "nearest" });
  }, [active]);
  // A native select or datalist cannot hold the matched-name bolding and descriptions.
  if (matches.length === 0)
    return (
      <div
        className="acpmux-slash-menu acpmux-slash-empty"
        id="acpmux-slash-menu"
        // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
        role="listbox"
        aria-label={COMPOSER_LABELS.commands}
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
      aria-label={COMPOSER_LABELS.commands}
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
    const escape = /^(\\[!-/:-@[-`{-~]|&(#x[0-9a-f]+|#[0-9]+|[a-z][a-z0-9]*);)/i.exec(
      markdown.slice(index),
    );
    index += escape ? escape[0].length : 1;
  }
  return index;
}
