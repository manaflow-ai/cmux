import React, { memo, useEffect, useRef, useState } from "react";
import { Keycap } from "../Keycap";
import { useT } from "../i18n";
import { inlineText } from "../question/inlineText";
import type { NextStepAsk } from "./nextStepAsk";
import "./NextStepCard.css";

/// The prompt's typed text, without the placeholder the composer keeps beside the editor.
const composerText = (document: Document) =>
  document.querySelector(".acpmux-composer-prompt .acpmux-md-root")?.textContent?.trim() ?? "";

/// A tagged ask at the end of a turn (nextStepAsk.ts) as Claude desktop's next-step box draws it
/// (Leo's 2026-11-03 reference): the question, a muted line of what the agent added after it, and
/// its answers as buttons in one row, the first filled with ⌘↩ on it (Yes and Not now for a yes-or-no ask). A click sends that answer as
/// the person's reply through the composer's send path, so it shows as their prompt and starts the
/// next turn. Once a prompt follows, the card folds to the question and the answer in grey, as an
/// answered AskUserQuestion does (QuestionCard.tsx AnsweredQuestion). ⌘↩ sends the first answer
/// from anywhere in the pane while the composer is empty; a draft keeps the key.
export const NextStepCard = memo(function NextStepCard({
  ask,
  answer,
  onAnswer,
}: {
  ask: NextStepAsk;
  /// What the person answered (the next prompt), once there is one.
  answer?: string;
  /// Sends an answer; absent where this pane cannot send (View Only, a read-only pane).
  onAnswer?: (text: string) => Promise<unknown>;
}) {
  const t = useT();
  const [sending, setSending] = useState<string>();
  const primary = useRef<HTMLButtonElement>(null);
  const pending = answer === undefined && onAnswer !== undefined;
  useEffect(() => {
    if (!pending) return;
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== "Enter" || !event.metaKey || event.ctrlKey || event.altKey || event.shiftKey) return;
      if (event.isComposing || composerText(document) !== "") return;
      // Another card that takes ⌘↩ (a waiting question) keeps it.
      if (document.querySelector(".acpmux-question-ask")) return;
      event.preventDefault();
      event.stopPropagation();
      primary.current?.click();
    };
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, [pending]);
  if (answer !== undefined) {
    // An answer the card made up (Yes, Not now) reads in the pane's words.
    const made = ask.options.find((option) => option.key && option.label === answer)?.key;
    return (
      <div className="acpmux-question-answered acpmux-next-step acpmux-next-step--answered">
        <span className="acpmux-hidden-label">{t("question.answered")}</span>
        <div className="acpmux-question-answered-item">
          <span className="acpmux-question-answered-prompt">{inlineText(ask.question)}</span>
          <span className="acpmux-question-answered-answer">{made ? t(made) : inlineText(answer)}</span>
        </div>
      </div>
    );
  }
  const send = (label: string) => {
    if (!onAnswer || sending !== undefined) return;
    setSending(label);
    void onAnswer(label).finally(() => setSending(undefined));
  };
  return (
    <div className="acpmux-next-step" role="group" aria-label={ask.question}>
      <p className="acpmux-next-step__question">{inlineText(ask.question)}</p>
      {ask.detail && <p className="acpmux-next-step__detail">{inlineText(ask.detail)}</p>}
      {onAnswer && (
        <div className="acpmux-next-step__answers">
          {ask.options.map((option, index) => (
            <button
              key={option.label}
              ref={index === 0 ? primary : undefined}
              type="button"
              className={index === 0 ? "acpmux-next-step__answer is-primary" : "acpmux-next-step__answer"}
              aria-keyshortcuts={index === 0 ? "Meta+Enter" : undefined}
              disabled={sending !== undefined}
              onClick={() => send(option.label)}
            >
              {option.key ? t(option.key) : inlineText(option.label)}
              {index === 0 && <Keycap>⌘↩</Keycap>}
            </button>
          ))}
        </div>
      )}
    </div>
  );
});
