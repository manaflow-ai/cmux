import React, { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import type { AcpmuxSnapshot } from "./model";
import { ArrowUpIcon, StopIcon } from "./ComposerPickers";
import { applyCommand, matchCommands, slashQuery, type SlashCommand, type SlashMatch } from "./slashCommands";

/// Composer copy. English defaults until the host passes localized labels, as the rest of the pane does today.
/// How long after a send the Stop button that replaces Send ignores clicks.
const STOP_GUARD_MS = 600;

export const COMPOSER_LABELS = {
  placeholder: "Ask anything",
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
  /// A button at the bar's left edge, such as attach.
  leading?: React.ReactNode;
  /// Buttons before Send, such as the dictation mic.
  accessory?: React.ReactNode;
};

/// The prompt box with the agent's `/` command menu: one rounded bar holding
/// the prompt and a round Send button, which turns into Stop while a turn runs
/// and the prompt is empty, with the mode and model as small muted text below. Enter sends and
/// Shift+Enter breaks the line. The menu opens while the prompt is a single
/// leading `/word`, filters as it grows, and picking a command writes `/name `
/// so its arguments can follow.
export function Composer({ snapshot, chips: Chips, onSend, onStop, leading, accessory }: Props) {
  const [text, setText] = useState("");
  const [caret, setCaret] = useState(0);
  const [active, setActive] = useState(0);
  const [dismissed, setDismissed] = useState<string | undefined>();
  const textarea = useRef<HTMLTextAreaElement>(null);
  const pendingCaret = useRef<number | undefined>(undefined);
  // Send becomes Stop in place once the turn starts; a second click of a
  // double-click, or a click right after Enter, must not cancel the new turn.
  const sentAt = useRef(0);
  // Send and Stop are separate buttons, so focus on Send moves to whichever replaces it.
  const refocusSend = useRef(false);
  const sendButton = useRef<HTMLButtonElement>(null);
  useLayoutEffect(() => {
    if (!refocusSend.current) return;
    const focused = document.activeElement;
    // The user moved on before the turn started: leave their focus alone.
    if (focused && focused !== document.body && focused !== sendButton.current) { refocusSend.current = false; return; }
    sendButton.current?.focus();
    if (snapshot.isWorking) refocusSend.current = false;
  });
  const commands = snapshot.commands;
  const query = slashQuery(text, caret);
  const open = query !== undefined && dismissed !== text;
  const matches = useMemo(() => (open ? matchCommands(commands ?? [], query ?? "") : []), [commands, open, query]);

  useEffect(() => setActive(0), [query]);
  // A live command update can shrink the list under the selection.
  const selected = Math.min(active, Math.max(matches.length - 1, 0));
  useLayoutEffect(() => {
    if (pendingCaret.current === undefined || !textarea.current) return;
    textarea.current.setSelectionRange(pendingCaret.current, pendingCaret.current);
    pendingCaret.current = undefined;
  });

  const edit = (value: string, at: number) => { setText(value); setCaret(at); setDismissed(undefined); };
  const pick = (command: SlashCommand) => {
    const next = applyCommand(text, caret, command);
    pendingCaret.current = next.caret;
    edit(next.text, next.caret);
    textarea.current?.focus();
  };
  const submit = (event: React.SyntheticEvent) => {
    event.preventDefault();
    const prompt = text.trim();
    if (!prompt) return;
    edit("", 0);
    sentAt.current = Date.now();
    refocusSend.current = document.activeElement?.classList.contains("acpmux-send") ?? false;
    onSend(prompt);
  };
  const stopTurn = () => { if (Date.now() - sentAt.current > STOP_GUARD_MS) onStop(); };
  const keyDown = (event: React.KeyboardEvent<HTMLTextAreaElement>) => {
    // Every key belongs to the input method while it composes, not only Enter.
    if (event.nativeEvent.isComposing || event.nativeEvent.keyCode === 229) return;
    const plain = !event.shiftKey && !event.altKey && !event.metaKey && !event.ctrlKey;
    // Enter sends unless it picks a command: with the menu closed, with nothing
    // to pick (an unknown command or a pasted path), or on a command already
    // typed in full that takes no arguments.
    const typedInFull = matches[selected]?.command.name === query && !matches[selected]?.command.hint;
    if (event.key === "Enter" && plain && (!open || matches.length === 0 || typedInFull)) { submit(event); return; }
    if (!open) return;
    if (event.key === "Escape") { event.preventDefault(); event.stopPropagation(); setDismissed(text); return; }
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
  const track = (event: React.SyntheticEvent<HTMLTextAreaElement>) => setCaret(event.currentTarget.selectionStart);

  const stop = snapshot.isWorking && !text.trim();
  return <form className="acpmux-composer" onSubmit={submit}>
    {open && <SlashMenu matches={matches} active={selected} empty={!commands?.length ? COMPOSER_LABELS.noCommands : COMPOSER_LABELS.noMatchingCommands} onHover={setActive} onPick={pick} />}
    {snapshot.queue.length > 0 && <ol className="acpmux-queue" aria-label={COMPOSER_LABELS.queue}>
      {snapshot.queue.map((entry) => <li className="acpmux-queued" key={entry.id} title={entry.prompt}><span className="acpmux-queued-label">{COMPOSER_LABELS.queued}</span><span className="acpmux-queued-text">{entry.prompt}</span></li>)}
    </ol>}
    <div className="acpmux-composer-box">
      {leading}
      {/* A textarea that drives a listbox: a native combobox cannot hold a multi-line prompt. */}
      <textarea ref={textarea} className="acpmux-composer-field" aria-label={COMPOSER_LABELS.prompt} name="prompt" rows={1} placeholder={COMPOSER_LABELS.placeholder} value={text}
        // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
        role="combobox" aria-expanded={open} aria-controls={open ? "acpmux-slash-menu" : undefined} aria-autocomplete="list"
        aria-activedescendant={open && matches.length > 0 ? `acpmux-slash-${selected}` : undefined}
        onChange={(event) => edit(event.target.value, event.target.selectionStart)} onSelect={track} onKeyDown={keyDown} />
      {accessory}
      {stop
        ? <button key="stop" ref={sendButton} type="button" className="acpmux-send acpmux-cancel" aria-label={COMPOSER_LABELS.stop} title={COMPOSER_LABELS.stop} onClick={stopTurn}><StopIcon /></button>
        : <button key="send" ref={sendButton} type="submit" className={`acpmux-send${text.trim() ? " acpmux-send-ready" : ""}`} aria-label={COMPOSER_LABELS.send} title={COMPOSER_LABELS.send}><ArrowUpIcon /></button>}
    </div>
    <div className="acpmux-composer-meta"><Chips snapshot={snapshot} /></div>
  </form>;
}

function SlashMenu({ matches, active, empty, onHover, onPick }: { matches: SlashMatch[]; active: number; empty: string; onHover(index: number): void; onPick(command: SlashCommand): void }) {
  const list = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => { list.current?.querySelector<HTMLElement>(`#acpmux-slash-${active}`)?.scrollIntoView?.({ block: "nearest" }); }, [active]);
  // A native select or datalist cannot hold the matched-name bolding and descriptions.
  // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
  if (matches.length === 0) return <div className="acpmux-slash-menu acpmux-slash-empty" id="acpmux-slash-menu" role="listbox" aria-label={COMPOSER_LABELS.commands}>{empty}</div>;
  // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
  return <div ref={list} className="acpmux-slash-menu" id="acpmux-slash-menu" role="listbox" aria-label={COMPOSER_LABELS.commands}>
    {/* Virtual focus: the prompt keeps focus and names the row through aria-activedescendant. */}
    {matches.map((match, index) => <div key={match.command.name} id={`acpmux-slash-${index}`}
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
      role="option" tabIndex={-1} aria-selected={index === active}
      className={index === active ? "acpmux-slash-row acpmux-slash-active" : "acpmux-slash-row"}
      onMouseMove={() => { if (index !== active) onHover(index); }} onMouseDown={(event) => { event.preventDefault(); onPick(match.command); }}>
      <span className="acpmux-slash-name">/<Highlighted name={match.command.name} ranges={match.ranges} /></span>
      {match.command.hint && <span className="acpmux-slash-hint">{match.command.hint}</span>}
      <span className="acpmux-slash-description">{match.command.description}</span>
    </div>)}
  </div>;
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
