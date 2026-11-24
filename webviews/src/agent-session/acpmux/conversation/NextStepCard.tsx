import React, { memo, useEffect, useRef, useState, useSyncExternalStore, useLayoutEffect } from "react";
import { DismissButton } from "../../../ui/DismissButton";
import { Icon } from "../icons/Icon";
import { useT } from "../i18n";
import { ArrowRight } from "./icons";
import { focusRoute } from "../../../ui/focusRoute";
import { inlineText } from "../question/inlineText";
import { answerPrompt, type NextStepAsk } from "./nextStepAsk";
import {
  answerState,
  claimAnswer,
  givenAnswer,
  setAnswerState,
  subscribeAnswers,
  type AnswerState,
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
/// It is drawn as the question card (QuestionCard.tsx, Lucas 2026-11-24: one look for every ask): the
/// "Needs your input" line (with close where it can be dismissed), the question as the title, the
/// answers as numbered rows where a click (or its number key) sends, the arrow on the row ⌘↩ sends,
/// and a last row where the person types an answer of their own (Return sends it).
/// The whole ask shows, wrapped at word breaks, as Claude's question card shows its question (a
/// coordinator's [irreversible] ask was cut mid-word). Only a very long one stops at
/// `--acpmux-next-step-lines` lines (its tail at `--acpmux-next-step-detail-lines`) with Show more
/// under it, which opens the rest in place: the answers keep their order under the text.
/// An answer row's keys: its number (1-9), and ⌘↩ on the first while the composer hands it the key.
function answerKeys(index: number, primary: boolean): string | undefined {
  const keys = [index < 9 ? String(index + 1) : undefined, primary ? "Meta+Enter" : undefined].filter(Boolean);
  return keys.length ? keys.join(" ") : undefined;
}

export const NextStepCard = memo(function NextStepCard({
  ask,
  answer,
  superseded = false,
  onAnswer,
  registerKey,
  answerKey,
  asker,
  className,
  onDismiss,
}: {
  ask: NextStepAsk;
  className?: string;
  /// Puts the pinned copy away (PendingAsks.tsx): the header's close. The transcript's card has none.
  onDismiss?: () => void;
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
  // A failed send gives the typed answer back with the keyboard, so Return retries it.
  const field = useRef<HTMLInputElement>(null);
  useEffect(() => {
    if (failed && field.current?.value) focusRoute(field.current, "system", "a typed answer that was not sent");
  }, [failed]);
  // A number key presses its answer's row while the focus is in the card (not in the typed answer).
  const card = useRef<HTMLFieldSetElement>(null);
  useEffect(() => {
    const element = card.current;
    if (!element || !pending) return;
    const press = (event: KeyboardEvent) => {
      if (event.metaKey || event.ctrlKey || event.altKey || event.shiftKey) return;
      if (!/^[1-9]$/.test(event.key) || (event.target as HTMLElement).closest("input")) return;
      // A held digit answers once; its repeats stay claimed so none falls through as typed text.
      event.preventDefault();
      if (event.repeat) return;
      const row = element.querySelectorAll<HTMLButtonElement>(".acpmux-next-step__answer")[Number(event.key) - 1];
      row?.click();
    };
    // ui-allow: number keys answer the card while focus is in it, as the question card's rows do.
    element.addEventListener("keydown", press);
    return () => element.removeEventListener("keydown", press);
  }, [pending]);
  // Whether the question or its tail runs past its cap: only then is there a Show more to offer.
  const [whole, setWhole] = useState(false);
  // The typed answer stays while it is on its way, so a failed send gives it back to retry. The
  // pinned copy leaves while its answer goes (PendingAsks.tsx), so a failure hands its words back
  // through the shared state (`typed`) when it returns.
  const [draft, setDraft] = useState(() => (state.failed ? (state.typed ?? "") : ""));
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
  const send = (text: string, typed = false) => {
    const label = text.trim();
    if (!onAnswer || sending !== undefined || !label) return;
    if (answerKey) claimAnswer(answerKey, label);
    update({ sending: label });
    // The answer goes as a reply to the ask: the question quoted with who asked, then the answer
    // (nextStepAsk.ts `answerPrompt`), so the bubble shows what it answers.
    void onAnswer(answerPrompt(ask.question, label, asker)).then(
      () => update({ sent: label }),
      () => update({ failed: true, typed: typed ? text : undefined }),
    );
  };
  return (
    <fieldset ref={card} className={`acpmux-next-step${className ? ` ${className}` : ""}`} aria-label={ask.question}>
      {(onAnswer || onDismiss) && (
        <div className="acpmux-question-bar acpmux-next-step__bar">
          <span>
            <Icon name="status.question" size={14} />
            {t("question.needsInput")}
          </span>
          {onDismiss && <DismissButton label={t("message.dismiss")} onDismiss={onDismiss} />}
        </div>
      )}
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
              aria-keyshortcuts={answerKeys(index, index === 0 && registerKey !== undefined)}
              disabled={sending !== undefined}
              onClick={() => send(option.label)}
            >
              <span className="acpmux-question-number" aria-hidden="true">
                {index + 1}
              </span>
              <span className="acpmux-next-step__label">{option.key ? t(option.key) : inlineText(option.label)}</span>
              <ArrowRight size={12} className="acpmux-next-step__arrow" />
            </button>
          ))}
        </div>
      )}
      {onAnswer && ask.options.length > 0 && (
        <label className="acpmux-question-footer acpmux-next-step__other">
          <span className="acpmux-question-number" data-edit="" aria-hidden="true">
            <Icon name="action.edit" size={12} />
          </span>
          <input
            ref={field}
            type="text"
            aria-label={t("question.other")}
            placeholder={t("question.otherPlaceholder")}
            value={draft}
            disabled={sending !== undefined}
            onChange={(event) => setDraft(event.currentTarget.value)}
            onKeyDown={(event) => {
              // Plain Return sends; a chord with Shift, Option, Control or ⌘ stays the field's.
              if (event.key !== "Enter" || event.nativeEvent.isComposing || event.keyCode === 229) return;
              if (event.shiftKey || event.altKey || event.ctrlKey || event.metaKey) return;
              event.preventDefault();
              send(draft, true);
            }}
          />
        </label>
      )}
      {failed && <output className="acpmux-next-step__detail">{t("prompt.notSentAgain")}</output>}
    </fieldset>
  );
});
