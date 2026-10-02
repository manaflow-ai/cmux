import React, { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import type { AcpmuxSnapshot } from "./model";
import { applyCommand, matchCommands, slashQuery, type SlashCommand, type SlashMatch } from "./slashCommands";

/// Composer copy. English defaults until the host passes localized labels, as the rest of the pane does today.
export const COMPOSER_LABELS = {
  placeholder: "Ask anything",
  prompt: "Prompt",
  send: "Send",
  stop: "Stop",
  commands: "Commands",
  noCommands: "No commands",
  noMatchingCommands: "No matching commands",
};

type Props = {
  snapshot: AcpmuxSnapshot;
  chips: React.ComponentType<{ snapshot: AcpmuxSnapshot }>;
  onSend(text: string): void;
  onStop(): void;
};

/// The prompt box with the agent's `/` command menu. The menu opens while the
/// prompt is a single leading `/word`, filters as it grows, and picking a
/// command writes `/name ` so its arguments can follow.
export function Composer({ snapshot, chips: Chips, onSend, onStop }: Props) {
  const [text, setText] = useState("");
  const [caret, setCaret] = useState(0);
  const [active, setActive] = useState(0);
  const [dismissed, setDismissed] = useState<string | undefined>();
  const textarea = useRef<HTMLTextAreaElement>(null);
  const pendingCaret = useRef<number | undefined>(undefined);
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
  const submit = (event: React.FormEvent) => {
    event.preventDefault();
    const prompt = text.trim();
    if (!prompt) return;
    edit("", 0);
    onSend(prompt);
  };
  const keyDown = (event: React.KeyboardEvent<HTMLTextAreaElement>) => {
    // Every key belongs to the input method while it composes, not only Enter.
    if (!open || event.nativeEvent.isComposing || event.nativeEvent.keyCode === 229) return;
    if (event.key === "Escape") { event.preventDefault(); event.stopPropagation(); setDismissed(text); return; }
    if (matches.length === 0) return;
    const plain = !event.shiftKey && !event.altKey && !event.metaKey && !event.ctrlKey;
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

  return <form className="acpmux-composer" onSubmit={submit}>
    {open && <SlashMenu matches={matches} active={selected} empty={!commands?.length ? COMPOSER_LABELS.noCommands : COMPOSER_LABELS.noMatchingCommands} onHover={setActive} onPick={pick} />}
    <Chips snapshot={snapshot} />
    {/* A textarea that drives a listbox: a native combobox cannot hold a multi-line prompt. */}
    <textarea ref={textarea} aria-label={COMPOSER_LABELS.prompt} name="prompt" rows={2} placeholder={COMPOSER_LABELS.placeholder} value={text}
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
      role="combobox" aria-expanded={open} aria-controls={open ? "acpmux-slash-menu" : undefined} aria-autocomplete="list"
      aria-activedescendant={open && matches.length > 0 ? `acpmux-slash-${selected}` : undefined}
      onChange={(event) => edit(event.target.value, event.target.selectionStart)} onSelect={track} onKeyDown={keyDown} />
    <button type="submit">{COMPOSER_LABELS.send}</button>
    <button type="button" className="acpmux-cancel" onClick={onStop}>{COMPOSER_LABELS.stop}</button>
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
