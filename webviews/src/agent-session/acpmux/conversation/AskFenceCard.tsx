// A ```ask fence drawn as a choice card (askFence.ts): its context muted, the question, then one
// button per option, the first filled, as Claude desktop draws an ask. A click sends the option as
// the person's next prompt through the composer's send (TurnActions `reply`), so it shows as their
// message and starts the agent's next turn, or queues behind one running. Then the card reads as
// answered: the question with the chosen option under it in grey. Nothing is sent but on a click,
// and where the pane cannot send (View Only, a read-only pane) the buttons stay disabled.
import { memo, useContext, useState, useSyncExternalStore, type ReactNode } from "react";
import { useT } from "../i18n";
import { inlineText } from "../question/inlineText";
import type { AskFence } from "./askFence";
import { TurnActionsContext } from "./turnActions";

// The option chosen on each ask this page sent, by its fence text: a row the transcript unmounts
// and draws again (scrolled away, a re-render per token) keeps its answer.
const chosen = new Map<string, string>();
const listeners = new Set<() => void>();
const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => listeners.delete(listener);
};
const choose = (key: string, option: string | undefined) => {
  if (option === undefined) chosen.delete(key);
  else chosen.set(key, option);
  for (const listener of listeners) listener();
};

export const AskFenceCard = memo(function AskFenceCard({
  ask,
  code,
  actions,
}: {
  ask: AskFence;
  /// The fence's text, the key its answer is kept under.
  code: string;
  actions?: ReactNode;
}) {
  const t = useT();
  const reply = useContext(TurnActionsContext).reply;
  const read = () => chosen.get(code);
  const answer = useSyncExternalStore(subscribe, read, read);
  const [sending, setSending] = useState(false);
  if (answer !== undefined)
    return (
      <div className="cv-ask">
        <div className="acpmux-question-answered cv-ask-answered">
          <span className="acpmux-hidden-label">{t("question.answered")}</span>
          {ask.context.length > 0 && <span className="cv-ask-context">{inlineText(ask.context.join(" "))}</span>}
          <div className="acpmux-question-answered-item">
            <span className="acpmux-question-answered-prompt">{inlineText(ask.question)}</span>
            <span className="acpmux-question-answered-answer">{inlineText(answer)}</span>
          </div>
        </div>
        {actions}
      </div>
    );
  const send = (option: string) => {
    if (!reply || sending) return;
    setSending(true);
    // Answered at once; a send that fails gives the buttons back.
    choose(code, option);
    void reply(option).then(
      (sent) => {
        if (!sent) choose(code, undefined);
        setSending(false);
      },
      () => {
        choose(code, undefined);
        setSending(false);
      },
    );
  };
  return (
    <div className="cv-ask">
      <fieldset className="acpmux-question cv-ask-card" aria-busy={sending || undefined}>
        <legend className="cv-ask-head">
          {ask.context.length > 0 && <span className="cv-ask-context">{inlineText(ask.context.join(" "))}</span>}
          <span className="cv-ask-question">{inlineText(ask.question)}</span>
        </legend>
        <div className="cv-ask-options">
          {ask.options.map((option, index) => (
            <button
              key={option}
              type="button"
              className={index === 0 ? "acpmux-question-submit cv-ask-option" : "cv-ask-option"}
              data-primary={index === 0 || undefined}
              disabled={!reply || sending}
              onClick={() => send(option)}
            >
              {inlineText(option)}
            </button>
          ))}
        </div>
      </fieldset>
      {actions}
    </div>
  );
});
