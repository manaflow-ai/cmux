import { useId } from "react";
import { Markdown } from "./conversation/Markdown";
import { useT } from "./i18n";

// A chat that opened before it can resume here (cx-khns1): its folder is gone, or acpmux plans a
// terminal or a read-only transcript, so the pane holds a fresh chat. The handshake's `pastTurns`
// (acpmux's `_acpmux/chat_transcript`, read from the chat's own transcript) are drawn read-only
// where the new chat's hero would be, until the chat has a session.

export type PastTurn = { prompt: string; answer: string };

/// The handshake's `pastTurns`, malformed turns skipped; undefined when there are none.
export function readPastTurns(value: unknown): PastTurn[] | undefined {
  if (!Array.isArray(value)) return undefined;
  const turns = value.flatMap((turn: { prompt?: unknown; answer?: unknown } | null) =>
    typeof turn?.prompt === "string"
      ? [{ prompt: turn.prompt, answer: typeof turn.answer === "string" ? turn.answer : "" }]
      : [],
  );
  return turns.length ? turns : undefined;
}

export function PastChat({ turns, githubRepository }: { turns: PastTurn[]; githubRepository?: string }) {
  const t = useT();
  const labelId = useId();
  return (
    <section className="acpmux-past-chat" aria-labelledby={labelId}>
      <p className="acpmux-past-chat-label" id={labelId}>
        {t("pastChat.label")}
      </p>
      {turns.map((turn, index) => (
        <div className="acpmux-past-chat-turn" key={index}>
          <div className="cv-user">
            <div className="ui-glass cv-user__bubble selectable">{turn.prompt}</div>
          </div>
          {turn.answer && (
            <Markdown className="selectable" {...(githubRepository ? { githubRepository } : {})}>
              {turn.answer}
            </Markdown>
          )}
        </div>
      ))}
    </section>
  );
}
