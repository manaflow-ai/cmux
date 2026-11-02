// The guest's composer and its own messages (design/chat-multiplayer.md section 3): text only, no
// attachments, slash commands or pickers. A message waiting on the owner shows the guest's chip,
// the text and "Waiting for <owner>"; once decided it folds to one quiet line, "Sent: …",
// "Declined: …" or "Not sent: …", as the owner's own declined line does.
import { type KeyboardEvent, useState } from "react";
import { type StringKey, useT } from "../acpmux/i18n";
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
}: {
  prompts: readonly GuestPrompt[];
  me: Participant;
  owner: string;
}) {
  const t = useT();
  const open = prompts.filter(isOpen);
  const decided = prompts.filter((prompt) => !isOpen(prompt)).slice(-DECIDED_SHOWN);
  if (!open.length && !decided.length) return null;
  return (
    <section className="guest-mine" aria-live="polite">
      {decided.map((prompt) => (
        <p key={prompt.clientId} className="guest-mine__decided" data-state={prompt.state}>
          {t(
            prompt.reason === "share.too_many_held"
              ? "guest.prompt.tooManyHeld"
              : DECIDED_TEXT[prompt.state as "approved"],
            {
              text: firstLine(prompt.text),
            },
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

export function GuestComposer({
  onSend,
  onDraft,
}: {
  /** Sends the message; the page holds it from here. */
  onSend: (text: string) => void;
  /** The draft changed (typing `{on}`). */
  onDraft: (text: string) => void;
}) {
  const t = useT();
  const [text, setText] = useState("");
  const tooLong = promptBytes(text) > PROMPT_MAX_BYTES;
  const canSend = text.trim().length > 0 && !tooLong;
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
    if (event.key !== "Enter" || event.shiftKey || event.nativeEvent.isComposing) return;
    event.preventDefault();
    send();
  };
  return (
    <form
      className="guest-composer"
      onSubmit={(event) => {
        event.preventDefault();
        send();
      }}
    >
      <textarea
        className="guest-composer__field"
        aria-label={t("guest.composer.placeholder")}
        placeholder={t("guest.composer.placeholder")}
        rows={1}
        value={text}
        onChange={(event) => change(event.target.value)}
        onKeyDown={keyDown}
      />
      <button className="guest-join__button" type="submit" disabled={!canSend}>
        {t("guest.composer.send")}
      </button>
      {tooLong && (
        <p className="guest-composer__note" role="alert">
          {t("guest.composer.tooLong")}
        </p>
      )}
    </form>
  );
}
