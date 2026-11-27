// The guest's composer and its own messages (design/chat-multiplayer.md section 3): text only, no
// attachments, slash commands or pickers. A message waiting on the owner shows the guest's chip,
// the text and "Waiting for <owner>"; once decided it folds to one quiet line, "Sent: …",
// "Declined: …" or "Not sent: …", as the owner's own declined line does. A refused one (never held)
// ends in a quiet Try again, which sends it again with its own id and text.
import { type KeyboardEvent, type ReactNode, useState } from "react";
import { type StringKey, useT } from "../acpmux/i18n";
import type { QueuedPrompt } from "../acpmux/model";
import { AuthorChip } from "../acpmux/multiplayer/Faces";
import type { Participant } from "../acpmux/multiplayer/participants";
import { type GuestPrompt, isOpen, PROMPT_MAX_BYTES, promptBytes } from "./guestPrompts";

/** Decided messages shown under the waiting ones; older ones are in the transcript. */
const DECIDED_SHOWN = 3;

const DECIDED_TEXT: Record<Exclude<GuestPrompt["state"], "sending" | "held">, StringKey> = {
  approved: "guest.prompt.sent",
  declined: "guest.prompt.declined",
  removed: "guest.prompt.withdrawn",
  refused: "guest.prompt.refused",
};

const firstLine = (text: string) => text.trim().split("\n", 1)[0] ?? "";

export function GuestMessages({
  prompts,
  me,
  owner,
  onRetry,
}: {
  prompts: readonly GuestPrompt[];
  me: Participant;
  owner: string;
  /** Sends a refused message again (guestPrompts.ts retry); without it a refused line has no Try again. */
  onRetry?: (clientId: string) => void;
}) {
  const t = useT();
  const open = prompts.filter(isOpen);
  const decided = prompts.filter((prompt) => !isOpen(prompt)).slice(-DECIDED_SHOWN);
  if (!open.length && !decided.length) return null;
  return (
    <section className="guest-mine" aria-live="polite">
      {decided.map((prompt) => (
        <p key={prompt.clientId} className="guest-mine__decided" data-state={prompt.state}>
          <span className="guest-mine__decided-text">
            {t(
              prompt.reason === "share.too_many_held"
                ? "guest.prompt.tooManyHeld"
                : DECIDED_TEXT[prompt.state as "approved"],
              {
                text: firstLine(prompt.text),
              },
            )}
          </span>
          {/* retry-prompt-ok: the daemon refused this message with a reason (not a dropped connection, which
              resends by itself as `sending`); sending it again unchanged is the guest's call. */}
          {prompt.state === "refused" && onRetry && (
            <button className="guest-mine__retry" type="button" onClick={() => onRetry(prompt.clientId)}>
              {t("guest.prompt.tryAgain")}
            </button>
          )}
        </p>
      ))}
      {open.map((prompt) => (
        <div key={prompt.clientId} className="cv-user guest-mine__held" data-state={prompt.state}>
          <AuthorChip author={me} />
          <div className="ui-glass cv-user__bubble selectable">{prompt.text}</div>
          <span className="guest-mine__label">
            {prompt.state === "sending" ? t("guest.prompt.sending") : t("guest.prompt.waiting", { owner })}
          </span>
        </div>
      ))}
    </section>
  );
}

/** Whether a queue entry is a person's message that runs once the turn ends: not another agent's
 * message or inbox notice, not a subagent retry, and not one still waiting on the owner. */
export const runsAfterTurn = (entry: QueuedPrompt) =>
  !entry.message && !entry.inbox && !entry.retry && !entry.awaitingOwner && entry.prompt.trim() !== "";

/**
 * The messages waiting behind the agent's running turn, as the owner's composer queue shows them:
 * the guest sees a follow-up the moment the owner sends it, not when the turn ends and it becomes a
 * row (Leo, 2026-11-23: "Google Docs-esque type sharing"). Read only: no edit, steer or delete.
 */
export function GuestQueue({ queue, owner }: { queue: readonly QueuedPrompt[]; owner?: Participant }) {
  const t = useT();
  if (!queue.length) return null;
  return (
    <section className="guest-mine guest-queue" data-testid="guest-queue" aria-live="polite">
      {queue.map((entry) => {
        const author = entry.author ?? owner;
        return (
          <div key={entry.id} className="cv-user guest-mine__held">
            {author && <AuthorChip author={author} />}
            <div className="ui-glass cv-user__bubble selectable">{entry.prompt}</div>
            <span className="guest-mine__label">{t("composer.queued")}</span>
          </div>
        );
      })}
    </section>
  );
}

export function GuestComposer({
  onSend,
  onDraft,
  initialText = "",
  placeholder,
  sendIcon,
  disabled = false,
  enterSends = true,
  className,
}: {
  /** Sends the message; the page holds it from here. */
  onSend: (text: string) => void;
  /** The draft changed (typing `{on}`). */
  onDraft: (text: string) => void;
  /** The draft to start with (one kept across a reload). */
  initialText?: string;
  placeholder?: string;
  sendIcon?: ReactNode;
  disabled?: boolean;
  /** Phone keyboards keep Return for a new line. */
  enterSends?: boolean;
  className?: string;
}) {
  const t = useT();
  const [text, setText] = useState(initialText);
  const tooLong = promptBytes(text) > PROMPT_MAX_BYTES;
  const canSend = text.trim().length > 0 && !tooLong && !disabled;
  const change = (next: string) => {
    setText(next);
    onDraft(next);
  };
  const send = () => {
    if (!canSend) return;
    onSend(text);
    setText("");
  };
  const keyDown = (event: KeyboardEvent<HTMLTextAreaElement>) => {
    if (!enterSends || event.key !== "Enter" || event.shiftKey || event.nativeEvent.isComposing) return;
    event.preventDefault();
    send();
  };
  return (
    <form
      className={`guest-composer${className ? ` ${className}` : ""}`}
      onSubmit={(event) => {
        event.preventDefault();
        send();
      }}
    >
      <textarea
        className="guest-composer__field"
        aria-label={placeholder ?? t("guest.composer.placeholder")}
        placeholder={placeholder ?? t("guest.composer.placeholder")}
        disabled={disabled}
        rows={1}
        value={text}
        onChange={(event) => change(event.target.value)}
        onKeyDown={keyDown}
      />
      <button className="guest-join__button" type="submit" disabled={!canSend} aria-label={t("guest.composer.send")}>
        {sendIcon ?? t("guest.composer.send")}
      </button>
      {tooLong && (
        <p className="guest-composer__note" role="alert">
          {t("guest.composer.tooLong")}
        </p>
      )}
    </form>
  );
}
