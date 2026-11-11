import React, { memo, useEffect, useRef, useState, useSyncExternalStore } from "react";
import { Keycap } from "../Keycap";
import { useT } from "../i18n";
import { inlineText } from "../question/inlineText";
import { answerPrompt, type NextStepAsk, type WrapUpTry } from "./nextStepAsk";
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
/// A finished task's wrap-up adds how to try it (wrapUp.ts `tryOf`): the Try button, the Verify
/// steps with a box each to tick, and the Report link, in the same box under the recap, in every
/// state of the card (an answered question leaves the work there to try). Aziz, 2026-11-09:
/// "theres a direct way for me to try out and verify its work in addition to the artifact."
export const NextStepCard = memo(function NextStepCard({
  ask,
  answer,
  superseded = false,
  onAnswer,
  registerKey,
  answerKey,
  asker,
  onTry,
  onReport,
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
  /// Opens the Try target (a page in a browser tab, a command in a new terminal); absent where
  /// this pane cannot open tabs, which then shows the target as text.
  onTry?: (tryIt: WrapUpTry) => void;
  /// Opens the report.
  onReport?: (report: string) => void;
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
  const recapText = ask.recap ? <p className="acpmux-next-step__recap">{inlineText(ask.recap)}</p> : null;
  const tryBlock = ask.tryIt ? <TryBlock tryIt={ask.tryIt} onTry={onTry} onReport={onReport} /> : null;
  const recap = tryBlock ? (
    <>
      {recapText}
      {tryBlock}
    </>
  ) : (
    recapText
  );
  // A wrap-up with nothing to decide (wrapUp.ts): the recap alone, in the same box.
  if (!ask.question)
    return recapText || tryBlock ? (
      <div className="acpmux-next-step acpmux-next-step--recap" data-next-step-try={tryBlock ? "" : undefined}>
        {recap}
      </div>
    ) : null;
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

/// The Try button, the Verify steps and the Report link of a finished wrap-up. The button names
/// what it opens (the page's address or the command) under its label, so a click is never a
/// surprise; ticks are the person's own and stay in this view.
function TryBlock({
  tryIt,
  onTry,
  onReport,
}: {
  tryIt: WrapUpTry;
  onTry?: (tryIt: WrapUpTry) => void;
  onReport?: (report: string) => void;
}) {
  const t = useT();
  const [ticked, setTicked] = useState<ReadonlySet<number>>(new Set());
  const target = tryIt.url ?? tryIt.command;
  const tick = (index: number) =>
    setTicked((was) => {
      const next = new Set(was);
      if (next.has(index)) next.delete(index);
      else next.add(index);
      return next;
    });
  return (
    <div className="acpmux-next-step__try" data-try-kind={tryIt.url ? "url" : tryIt.command ? "command" : undefined}>
      {(target || tryIt.report) && (
        <div className="acpmux-next-step__try-row">
          {target && (
            <button
              type="button"
              className="acpmux-next-step__answer is-primary acpmux-next-step__try-button"
              disabled={!onTry}
              title={target}
              onClick={() => onTry?.(tryIt)}
            >
              <span aria-hidden="true">▶</span>
              {tryIt.label ?? t("wrapUp.try.default")}
            </button>
          )}
          {tryIt.report && (
            <button
              type="button"
              className="acpmux-next-step__answer acpmux-next-step__report"
              disabled={!onReport}
              title={tryIt.report}
              onClick={() => onReport?.(tryIt.report!)}
            >
              {t("wrapUp.try.report")}
            </button>
          )}
        </div>
      )}
      {target && <code className="acpmux-next-step__try-target">{target}</code>}
      {tryIt.verify.length > 0 && (
        <div className="acpmux-next-step__verify">
          <p className="acpmux-next-step__verify-head">{t("wrapUp.try.verify")}</p>
          <ul>
            {tryIt.verify.map((step, index) => (
              <li key={index}>
                <label>
                  <input type="checkbox" aria-label={step} checked={ticked.has(index)} onChange={() => tick(index)} />
                  <span>{inlineText(step)}</span>
                </label>
              </li>
            ))}
          </ul>
        </div>
      )}
    </div>
  );
}
