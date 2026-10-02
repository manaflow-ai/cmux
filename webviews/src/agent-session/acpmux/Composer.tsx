import React, { useEffect, useLayoutEffect, useMemo, useRef, useState } from "react";
import type { AcpmuxSnapshot } from "./model";
import { dragHasFiles, filesFrom, readAttachments, type AttachmentError, type ComposerAttachment } from "./attachments";
import { applyCommand, matchCommands, slashQuery, type SlashCommand, type SlashMatch } from "./slashCommands";

/// Composer copy. English defaults until the host passes localized labels, as the rest of the pane does today.
export const COMPOSER_LABELS = {
  placeholder: "Ask anything",
  prompt: "Prompt",
  send: "Send",
  steer: "Steer",
  steerHelp: "Send now, interrupting the current turn",
  queueHelp: "Send after the current turn",
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
};

function attachmentErrorText(error: AttachmentError): string {
  return COMPOSER_LABELS[error.reason].replace("{name}", error.name);
}

type Props = {
  snapshot: AcpmuxSnapshot;
  chips: React.ComponentType<{ snapshot: AcpmuxSnapshot }>;
  onSend(text: string, attachments: ComposerAttachment[]): void;
  /** Sends mid-turn, interrupting the agent, while a turn is running. */
  onSteer(text: string, attachments: ComposerAttachment[]): void;
  onStop(): void;
};

/// The prompt box with the agent's `/` command menu. The menu opens while the
/// prompt is a single leading `/word`, filters as it grows, and picking a
/// command writes `/name ` so its arguments can follow. Images and text files
/// dropped anywhere on the pane, or pasted, wait as chips above the prompt.
export function Composer({ snapshot, chips: Chips, onSend, onSteer, onStop }: Props) {
  const [text, setText] = useState("");
  const [caret, setCaret] = useState(0);
  const [active, setActive] = useState(0);
  const [dismissed, setDismissed] = useState<string | undefined>();
  const [attachments, setAttachments] = useState<ComposerAttachment[]>([]);
  const [attachError, setAttachError] = useState<string | undefined>();
  const [dropping, setDropping] = useState(false);
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

  const held = useRef(0);
  held.current = attachments.length;
  // Unknown capabilities (a new chat, an older daemon) let the agent decide.
  const allowImages = snapshot.summary?.promptCapabilities?.image !== false;
  const attach = useRef<(files: File[]) => Promise<void>>(async () => {});
  attach.current = async (files: File[]) => {
    if (files.length === 0) return;
    const read = await readAttachments(files, held.current, allowImages);
    setAttachments((current) => [...current, ...read.attachments]);
    setAttachError(read.errors[0] ? attachmentErrorText(read.errors[0]) : undefined);
  };
  // The whole pane takes a file drop; WebKit would otherwise open the file in place of the page.
  useEffect(() => {
    const over = (event: DragEvent) => { if (!dragHasFiles(event.dataTransfer)) return; event.preventDefault(); setDropping(true); };
    const leave = (event: DragEvent) => { if (!event.relatedTarget) setDropping(false); };
    const drop = (event: DragEvent) => { if (!dragHasFiles(event.dataTransfer)) return; event.preventDefault(); setDropping(false); void attach.current(filesFrom(event.dataTransfer)); };
    document.addEventListener("dragover", over);
    document.addEventListener("dragleave", leave);
    document.addEventListener("drop", drop);
    return () => { document.removeEventListener("dragover", over); document.removeEventListener("dragleave", leave); document.removeEventListener("drop", drop); };
  }, []);

  const edit = (value: string, at: number) => { setText(value); setCaret(at); setDismissed(undefined); };
  const pick = (command: SlashCommand) => {
    const next = applyCommand(text, caret, command);
    pendingCaret.current = next.caret;
    edit(next.text, next.caret);
    textarea.current?.focus();
  };
  /// Hands the prompt and its attachments to `deliver` and clears the composer.
  const take = (deliver: (text: string, attachments: ComposerAttachment[]) => void) => {
    const prompt = text.trim();
    if (!prompt && attachments.length === 0) return;
    edit("", 0);
    setAttachments([]);
    setAttachError(undefined);
    deliver(prompt, attachments);
  };
  const submit = (event: React.FormEvent) => { event.preventDefault(); take(onSend); };
  const empty = !text.trim() && attachments.length === 0;
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

  const paste = (event: React.ClipboardEvent<HTMLTextAreaElement>) => {
    const files = filesFrom(event.clipboardData);
    if (files.length === 0) return;
    event.preventDefault();
    void attach.current(files);
  };
  const remove = (id: string) => { setAttachments((current) => current.filter((attachment) => attachment.id !== id)); textarea.current?.focus(); };

  return <form className={dropping ? "acpmux-composer acpmux-composer-dropping" : "acpmux-composer"} onSubmit={submit}>
    {open && <SlashMenu matches={matches} active={selected} empty={!commands?.length ? COMPOSER_LABELS.noCommands : COMPOSER_LABELS.noMatchingCommands} onHover={setActive} onPick={pick} />}
    {(attachments.length > 0 || attachError || dropping) && <fieldset className="acpmux-attachments" aria-label={COMPOSER_LABELS.attachments}>
      {attachments.map((attachment) => <AttachmentChip key={attachment.id} attachment={attachment} onRemove={remove} />)}
      {dropping ? <span className="acpmux-attachment-note">{COMPOSER_LABELS.dropFiles}</span> : attachError && <output className="acpmux-attachment-note">{attachError}</output>}
    </fieldset>}
    <Chips snapshot={snapshot} />
    {/* A textarea that drives a listbox: a native combobox cannot hold a multi-line prompt. */}
    <textarea ref={textarea} aria-label={COMPOSER_LABELS.prompt} name="prompt" rows={2} placeholder={COMPOSER_LABELS.placeholder} value={text}
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
      role="combobox" aria-expanded={open} aria-controls={open ? "acpmux-slash-menu" : undefined} aria-autocomplete="list"
      aria-activedescendant={open && matches.length > 0 ? `acpmux-slash-${selected}` : undefined}
      onChange={(event) => edit(event.target.value, event.target.selectionStart)} onSelect={track} onKeyDown={keyDown} onPaste={paste} />
    <button type="submit" title={snapshot.isWorking ? COMPOSER_LABELS.queueHelp : undefined}>{COMPOSER_LABELS.send}</button>
    {snapshot.isWorking && <button type="button" className="acpmux-steer" title={COMPOSER_LABELS.steerHelp} disabled={empty} onClick={() => take(onSteer)}>{COMPOSER_LABELS.steer}</button>}
    <button type="button" className="acpmux-cancel" onClick={onStop}>{COMPOSER_LABELS.stop}</button>
  </form>;
}

function AttachmentChip({ attachment, onRemove }: { attachment: ComposerAttachment; onRemove(id: string): void }) {
  const remove = <button type="button" className="acpmux-attachment-remove" aria-label={COMPOSER_LABELS.removeAttachment.replace("{name}", attachment.name)} onClick={() => onRemove(attachment.id)}>×</button>;
  if (attachment.kind === "image") return <div className="acpmux-attachment acpmux-attachment-image" title={attachment.name}><img alt={attachment.name} src={`data:${attachment.mimeType};base64,${attachment.data}`} />{remove}</div>;
  return <div className="acpmux-attachment acpmux-attachment-file" title={attachment.name}><span>{attachment.name}</span>{remove}</div>;
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
