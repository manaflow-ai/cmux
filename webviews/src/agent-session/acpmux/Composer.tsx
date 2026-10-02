import React, { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import type { AcpmuxSnapshot } from "./model";
import { ComposerContext } from "./ComposerContext";
import { ArrowUpIcon, AtIcon, PaperclipIcon, Picker, PlusIcon, SlashIcon, StopIcon } from "./ComposerPickers";
import { applyCommand, matchCommands, slashQuery, type SlashCommand, type SlashMatch } from "./slashCommands";
import { seededText } from "./composerDraft";
import { MarkdownField, type MarkdownFieldHandle } from "./MarkdownField";

/// Composer copy. English defaults until the host passes localized labels, as the rest of the pane does today.
/// How long after a send the Stop button that replaces Send ignores clicks.
const STOP_GUARD_MS = 600;

export const COMPOSER_LABELS = {
  placeholder: "Ask anything, @ for context, / for commands",
  add: "Add",
  mention: "Mention a file or folder",
  attach: "Attach files or images",
  prompt: "Prompt",
  send: "Send",
  stop: "Stop",
  commands: "Commands",
  noCommands: "No commands",
  noMatchingCommands: "No matching commands",
  queue: "Queued prompts",
  queued: "Queued",
};

type Props = {
  snapshot: AcpmuxSnapshot;
  chips: React.ComponentType<{ snapshot: AcpmuxSnapshot }>;
  onSend(text: string): void;
  onStop(): void;
  /// Text the prompt starts with, such as what a chat opened from another tab inherited.
  /// Each new value fills an empty prompt once, caret at the end; it is never sent by itself.
  draft?: string;
  /// The bar's left button, such as attach; by default + opens the agent's commands. `null` leaves the slot empty.
  leading?: React.ReactNode;
  /// Buttons before Send, such as the dictation mic.
  accessory?: React.ReactNode;
  /// Opens the host's file and image picker; the + menu offers it only when set.
  onAttach?(): void;
  /// Starts a new chat in another project; the tray's project pill chooses only when set.
  onProject?(cwd: string): void;
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
  onAttach,
  onProject,
}: Props) {
  const [text, setText] = useState("");
  const [caret, setCaret] = useState(0);
  const [active, setActive] = useState(0);
  const [dismissed, setDismissed] = useState<string | undefined>();
  const field = useRef<MarkdownFieldHandle>(null);
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
  const query = slashQuery(text, caret);
  const open = query !== undefined && dismissed !== text;
  const matches = useMemo(() => (open ? matchCommands(commands ?? [], query ?? "") : []), [commands, open, query]);

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
  const submit = (event: { preventDefault(): void }) => {
    event.preventDefault();
    const prompt = unwrapped().trim();
    plusDraft.current = undefined;
    if (!prompt) return;
    edit("", 0);
    sentAt.current = Date.now();
    refocusSend.current = document.activeElement?.classList.contains("acpmux-send") ?? false;
    onSend(prompt);
  };
  /// + then Mention: an "@" at the caret, set off by a space, for the agent to read as a path.
  const mention = () => {
    if (composing.current) return;
    const at = caret;
    const before = text.slice(0, at);
    const insert = before && !/\s$/.test(before) ? " @" : "@";
    plusDraft.current = undefined;
    pendingCaret.current = at + insert.length;
    edit(before + insert + text.slice(at), at + insert.length);
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
  const stopTurn = () => {
    if (Date.now() - sentAt.current > STOP_GUARD_MS) onStop();
  };
  const keyDown = (event: KeyboardEvent) => {
    // Every key belongs to the input method while it composes, not only Enter.
    if (event.isComposing || event.keyCode === 229) return;
    const plain = !event.shiftKey && !event.altKey && !event.metaKey && !event.ctrlKey;
    // Enter sends unless it picks a command: with the menu closed, with nothing
    // to pick (an unknown command or a pasted path), or on a command already
    // typed in full that takes no arguments.
    const typedInFull = matches[selected]?.command.name === query && !matches[selected]?.command.hint;
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
    <form className="acpmux-composer" onSubmit={submit} onBlur={blur}>
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
      <ComposerContext summary={snapshot.summary} sessions={snapshot.sessions} onProject={onProject} />
      <div className="acpmux-composer-box">
        {/* Anchored to the field, like the picker menus, so a queue above it never pushes the menu up. */}
        {open && (
          <SlashMenu
            matches={matches}
            active={selected}
            empty={!commands?.length ? COMPOSER_LABELS.noCommands : COMPOSER_LABELS.noMatchingCommands}
            onHover={setActive}
            onPick={pick}
          />
        )}
        {/* An editable prompt that drives a listbox: a native combobox cannot hold a multi-line prompt. */}
        <MarkdownField
          ref={field}
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
            "aria-activedescendant": open && matches.length > 0 ? `acpmux-slash-${selected}` : undefined,
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
                {
                  choices: [
                    ...(onAttach ? [{ id: "attach", name: COMPOSER_LABELS.attach, icon: <PaperclipIcon /> }] : []),
                    { id: "mention", name: COMPOSER_LABELS.mention, icon: <AtIcon />, hint: "@" },
                    ...(commands?.length
                      ? [{ id: "commands", name: COMPOSER_LABELS.commands, icon: <SlashIcon />, hint: "/" }]
                      : []),
                  ],
                  onPick: (id) => (id === "attach" ? onAttach?.() : id === "mention" ? mention() : openCommands()),
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
                className={`acpmux-send${text.trim() ? " acpmux-send-ready" : ""}`}
                aria-label={COMPOSER_LABELS.send}
                title={COMPOSER_LABELS.send}
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
