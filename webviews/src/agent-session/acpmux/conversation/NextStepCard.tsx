import React, { memo, useEffect, useLayoutEffect, useRef, useState, useSyncExternalStore } from "react";
import { Keycap } from "../Keycap";
import { useT } from "../i18n";
import { inlineText } from "../question/inlineText";
import { answerPrompt, type NextStepAsk } from "./nextStepAsk";
import {
  answerState,
  claimAnswer,
  setAnswerState,
  subscribeAnswers,
  type AnswerState,
  givenAnswer,
} from "./waitingAskStore";
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
/// A click folds the card to its answer in the same frame, before any prompt row settles it: the
/// answer may wait in the queue behind a running turn, where no row settles it until the turn ends
/// (Leo, 2026-11-17, on a card that kept its buttons after "Plugged in": "after i click the
/// behaviour is very weird"). A send that fails brings the buttons back with "not sent".
/// The agent's own wrap-up call (wrapUp.ts) adds its recap, muted at the top of the same box
/// (reference claude/web/october-recap-card); with no question the box holds the recap alone.
/// The whole ask shows, wrapped at word breaks, as Claude's question card shows its question (a
/// coordinator's [irreversible] ask was cut mid-word). Only a very long one stops at
/// `--acpmux-next-step-lines` lines (its tail at `--acpmux-next-step-detail-lines`) with Show more
/// under it, which opens the rest in place: the answers keep their order under the text.
export const NextStepCard = memo(function NextStepCard({
  ask,
  answer,
  superseded = false,
  onAnswer,
  registerKey,
  answerKey,
  asker,
  className,
}: {
  ask: NextStepAsk;
  className?: string;
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
  const state = answerKey ? shared : own;
  const { sending, failed = false } = state;
  const update = (state: AnswerState) => (answerKey ? setAnswerState(answerKey, state) : setOwn(state));
  const primary = useRef<HTMLButtonElement>(null);
  // A recap alone has no answer to send, so it leaves ⌘↩ to the composer.
  const shown = answer ?? givenAnswer(state);
  const settled = shown !== undefined || superseded;
  const pending = !settled && onAnswer !== undefined && ask.options.length > 0;
  useEffect(() => {
    if (!pending || !registerKey) return;
    return registerKey(() => primary.current?.click());
  }, [pending, registerKey]);
  // Whether the question or its tail runs past its cap: only then is there a Show more to offer.
  const [whole, setWhole] = useState(false);
  const [clipped, setClipped] = useState(false);
  const textRef = useRef<HTMLDivElement>(null);
  useLayoutEffect(() => {
    const element = textRef.current;
    if (!element || whole) return;
    const measure = () =>
      setClipped(Array.from(element.children).some((child) => child.scrollHeight > child.clientHeight + 1));
    measure();
    if (typeof ResizeObserver === "undefined") return;
    const observer = new ResizeObserver(measure);
    observer.observe(element);
    return () => observer.disconnect();
  }, [ask.question, ask.detail, whole, settled]);
  const recap = ask.recap ? <p className="acpmux-next-step__recap">{inlineText(ask.recap)}</p> : null;
  // A wrap-up with nothing to decide (wrapUp.ts): the recap alone, in the same box.
  if (!ask.question) return recap ? <div className="acpmux-next-step acpmux-next-step--recap">{recap}</div> : null;
  if (settled) {
    // An answer the card made up (Yes, Not now) reads in the pane's words.
    const made = ask.options.find((option) => option.key && option.label === shown)?.key;
    return (
      <div className="acpmux-question-answered acpmux-next-step acpmux-next-step--answered">
        {recap}
        <span className="acpmux-hidden-label">{t("question.answered")}</span>
        <div className="acpmux-question-answered-item">
          <span className="acpmux-question-answered-prompt">{inlineText(ask.question)}</span>
          {shown !== undefined && (
            <span className="acpmux-question-answered-answer">{made ? t(made) : inlineText(shown)}</span>
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
      () => update({ sent: label }),
      () => update({ failed: true }),
    );
  };
  return (
    <fieldset className={`acpmux-next-step${className ? ` ${className}` : ""}`} aria-label={ask.question}>
      {recap}
      <div ref={textRef} className="acpmux-next-step__text" data-whole={whole || undefined}>
        <p className="acpmux-next-step__question">{inlineText(ask.question)}</p>
        {ask.detail && <p className="acpmux-next-step__detail">{inlineText(ask.detail)}</p>}
      </div>
      {(clipped || whole) && (
        <button
          type="button"
          className="acpmux-next-step__more"
          aria-expanded={whole}
          onClick={() => setWhole((value) => !value)}
        >
          {t(whole ? "message.less" : "message.more")}
        </button>
      )}
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
