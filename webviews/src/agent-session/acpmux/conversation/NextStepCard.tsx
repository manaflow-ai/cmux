import React, { memo, useEffect, useRef, useState, useSyncExternalStore } from "react";
import { Keycap } from "../Keycap";
import { useT } from "../i18n";
import { inlineText } from "../question/inlineText";
import { answerPrompt, type NextStepAsk } from "./nextStepAsk";
import { answerState, claimAnswer, setAnswerState, subscribeAnswers, type AnswerState } from "./waitingAskStore";
import "./NextStepCard.css";

/// A tagged ask at the end of a turn (nextStepAsk.ts) as Claude desktop's next-step box draws it
/// (Leo's 2026-11-03 reference): the question, a muted line of what the agent added after it, and
/// its answers as buttons in one row, the first filled with ⌘↩ on it (Yes and Not now for a yes-or-no ask). A click sends that answer as
/// the person's reply through the composer's send path, under a quote of the ask that names who
/// asked (nextStepAsk.ts `answerPrompt`), so it shows as their reply to the ask and starts the
/// next turn. Another prompt the person sends leaves the card answerable: it folds to the question
/// and the answer in grey, as an answered AskUserQuestion does (QuestionCard.tsx AnsweredQuestion),
/// only once a prompt picks one of its answers or a later turn ends on a card of its own
/// (turns.ts `settleNextSteps`). Leo, 2026-11-05, on Claude desktop's box: "after i sent a prompt
/// icouldn't select the thing... we can make a better thing in cmux-next for y'all to call".
/// ⌘↩ on an empty composer sends the first answer through `registerKey` (the composer's empty ⌘↩);
/// a draft keeps the key.
/// The agent's own wrap-up call (wrapUp.ts) adds its recap, muted at the top of the same box
/// (reference claude/web/october-recap-card); with no question the box holds the recap alone.
export const NextStepCard = memo(function NextStepCard({
  ask,
  answer,
  superseded = false,
  onAnswer,
  registerKey,
  answerKey,
  asker,
}: {
  ask: NextStepAsk;
  /// The answer a later prompt picked, or once `superseded`, what the person said after the card.
  answer?: string;
  /// A later card took over: this one folds, with `answer` when there is one.
  superseded?: boolean;
  /// Sends an answer; absent where this pane cannot send (View Only, a read-only pane).
  onAnswer?: (text: string) => Promise<unknown>;
  /// Hands the first answer to the composer's ⌘↩ while the card waits (TurnActions `nextStepKey`).
  registerKey?: (fire: () => void) => () => void;
  /// The card's key (waitingAskStore.ts `askKey`): its copies share one answer on its way, and the
  /// answer it sends settles this card, not a newer one with the same answers.
  answerKey?: string;
  /// Who asked (the chat's agent, `agentName`): the sent answer quotes the ask under this name.
  asker?: string;
}) {
  const t = useT();
  // The answer on its way and whether the last one failed: the card says so and keeps its
  // buttons, never drops it. Shared by the card's copies when it has a key.
  const [own, setOwn] = useState<AnswerState>({});
  const shared = useSyncExternalStore(
    subscribeAnswers,
    () => (answerKey ? answerState(answerKey) : own),
    () => own,
  );
  const { sending, failed = false } = answerKey ? shared : own;
  const update = (state: AnswerState) => (answerKey ? setAnswerState(answerKey, state) : setOwn(state));
  const primary = useRef<HTMLButtonElement>(null);
  // A recap alone has no answer to send, so it leaves ⌘↩ to the composer.
  const settled = answer !== undefined || superseded;
  const pending = !settled && onAnswer !== undefined && ask.options.length > 0;
  useEffect(() => {
    if (!pending || !registerKey) return;
    return registerKey(() => primary.current?.click());
  }, [pending, registerKey]);
  const recap = ask.recap ? <p className="acpmux-next-step__recap">{inlineText(ask.recap)}</p> : null;
  // A wrap-up with nothing to decide (wrapUp.ts): the recap alone, in the same box.
  if (!ask.question) return recap ? <div className="acpmux-next-step acpmux-next-step--recap">{recap}</div> : null;
  if (settled) {
    // An answer the card made up (Yes, Not now) reads in the pane's words.
    const made = ask.options.find((option) => option.key && option.label === answer)?.key;
    return (
      <div className="acpmux-question-answered acpmux-next-step acpmux-next-step--answered">
        {recap}
        <span className="acpmux-hidden-label">{t("question.answered")}</span>
        <div className="acpmux-question-answered-item">
          <span className="acpmux-question-answered-prompt">{inlineText(ask.question)}</span>
          {answer !== undefined && (
            <span className="acpmux-question-answered-answer">{made ? t(made) : inlineText(answer)}</span>
          )}
        </div>
      </div>
    );
  }
  const send = (label: string) => {
    if (!onAnswer || sending !== undefined) return;
    if (answerKey) claimAnswer(answerKey, label);
    update({ sending: label });
    // The answer goes as a reply to the ask: the question quoted with who asked, then the answer
    // (nextStepAsk.ts `answerPrompt`), so the bubble shows what it answers.
    void onAnswer(answerPrompt(ask.question, label, asker)).then(
      () => update({}),
      () => update({ failed: true }),
    );
  };
  return (
    <fieldset className="acpmux-next-step" aria-label={ask.question}>
      {recap}
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
              aria-keyshortcuts={index === 0 && registerKey ? "Meta+Enter" : undefined}
              disabled={sending !== undefined}
              onClick={() => send(option.label)}
            >
              {option.key ? t(option.key) : inlineText(option.label)}
              {index === 0 && registerKey && <Keycap>⌘↩</Keycap>}
            </button>
          ))}
        </div>
      )}
      {failed && <output className="acpmux-next-step__detail">{t("prompt.notSentAgain")}</output>}
    </fieldset>
  );
});
