// The agent's questions in the composer hat (hatModel.ts): one band over the composer that holds
// every question waiting on the person, with one yellow mark, a count, left and right to step through
// them, and their answers as buttons, so a click answers and nothing has to be typed. Leo, 2026-11-07:
// "the composer hat can become a dual thing where you can go through it and, like, click left and
// right through things and be able to answer things as they come". It never takes the place of Jump
// to latest, which stays the plain button over the transcript (Leo: "it, like, replaced the, you
// know, the jump to bottom area with, like, the needs you and the yellow dot, but it's like, that's
// too much"); the sidebar's Needs you dot stays the signal that a chat waits.
//
// One state transition (design/motion.md): the band's height is measured and eased on
// --agent-motion-move whenever what it holds changes (it arrives, a step shows a taller or shorter
// question, the last one leaves), and the question it shows crossfades with a short slide the way
// the step went. Leaving, the band keeps its last question until its height reaches zero, so nothing
// pops out; with motion off the change is one frame. Questions already waiting when it mounts draw
// at once. Arms in hatQuestions.experiment.ts.
//
// Each question can be put away (Leo, 2026-11-11: "there's no close button :("): the shared × at the
// head's end (ui/DismissButton.tsx), faded in while the pointer is over the band or the focus is in
// it, and Escape while the focus is in it. It holds its room at rest, so revealing it moves nothing,
// and the head's text is cut to the room beside it. Dismissing marks the question seen in this chat
// (App.tsx `dismissHatQuestion`, waitingAskStore.ts): it leaves the hat, while the ask itself still
// waits where it was asked (its card, its chat, the sidebar's Needs you dot). A started chat's name
// takes its own line over the question, so neither is cut at a fixed share of the band.
import React, { type CSSProperties, useEffect, useLayoutEffect, useRef, useState } from "react";
import { experimentArm } from "../../../experiments/experiment";
import { DismissButton } from "../../../ui/DismissButton";
import { useT, type StringKey } from "../i18n";
import { Icon } from "../icons/Icon";
import { inlineText } from "./inlineText";
import { keepShown, type HatAnswer, type HatQuestion, type HatTag } from "./hatModel";
import { hatQuestionsLook } from "./hatQuestions.experiment";
import "./hatQuestions.css";

const TAG_KEY: Record<HatTag, StringKey> = {
  taste: "hat.tag.taste",
  irreversible: "hat.tag.irreversible",
  outward: "hat.tag.outward",
  physical: "hat.tag.physical",
  "check-in": "hat.tag.checkIn",
  "for you": "hat.tag.forYou",
};

export type HatQuestionActions = {
  /// Sends one of the question's answers; rejects when it was refused (the band takes input again).
  answer(question: HatQuestion, answer: HatAnswer): Promise<unknown>;
  /// Puts the cursor in the composer: what the person types there answers it (and withdraws a
  /// waiting question, App.tsx `withdrawForTypedReply`).
  type(question: HatQuestion): void;
  /// Brings the question's full card into view (one that needs more than a click).
  showCard(question: HatQuestion): void;
  /// Opens a started chat's question in its chat.
  open(question: HatQuestion): void;
  /// Puts the question away from the hat: the person has seen it (the × or Escape).
  dismiss(question: HatQuestion): void;
};

/// Whether the band's height transition is still running; with motion off it never starts.
const moving = (element: HTMLElement | null) =>
  element?.getAnimations().some((animation) => animation.playState === "running") ?? false;

export function HatQuestions({
  questions,
  actions,
  look: lookProp,
  dismissLook = "hover",
}: {
  questions: readonly HatQuestion[];
  actions: HatQuestionActions;
  /// The gallery's arm; the pane reads the experiment.
  look?: "band" | "line" | "chip";
  /// How the × shows: on hover in its own room (shipped), always, or over the band's corner (the
  /// gallery's comparison, which shows why it needs its own room).
  dismissLook?: "hover" | "always" | "corner";
}) {
  const t = useT();
  const [armRead] = useState(() => experimentArm(hatQuestionsLook));
  const look = lookProp ?? armRead;
  // What is drawn: the questions, or while the band leaves, the last of them.
  const [kept, setKept] = useState<readonly HatQuestion[]>(questions);
  const leaving = questions.length === 0 && kept.length > 0;
  if (questions.length > 0 && kept !== questions) setKept(questions);
  const drawn = questions.length > 0 ? questions : kept;
  // The question shown, by id, so a list that changes around it keeps it.
  const [shownId, setShownId] = useState<string | undefined>(drawn[0]?.id);
  const order = useRef<readonly string[]>(drawn.map((question) => question.id));
  const index = keepShown(drawn, shownId, order.current);
  const shown = drawn[index];
  useLayoutEffect(() => {
    order.current = drawn.map((question) => question.id);
    if (shown && shown.id !== shownId) setShownId(shown.id);
  }, [drawn, shown, shownId]);
  const [direction, setDirection] = useState<"next" | "previous">("next");
  const [open, setOpen] = useState(false);
  const [sending, setSending] = useState<string>();
  const [failed, setFailed] = useState<string>();
  // A new question shown is a new chance to answer: the last one's state goes.
  useEffect(() => {
    setSending(undefined);
    setFailed(undefined);
  }, [shown?.id]);

  // The band's height follows its content's, eased; zero while leaving or before it arrives.
  const outer = useRef<HTMLDivElement>(null);
  const inner = useRef<HTMLDivElement>(null);
  const [height, setHeight] = useState(0);
  // Questions already waiting when the pane opens (or shows another chat, which mounts it again) are
  // its start state, not a change: the band draws at its height at once, and eases only from the
  // next frame on.
  const [arrived, setArrived] = useState(() => questions.length > 0);
  const [settled, setSettled] = useState(false);
  useEffect(() => {
    const frame = requestAnimationFrame(() => setSettled(true));
    return () => cancelAnimationFrame(frame);
  }, []);
  const present = drawn.length > 0;
  useLayoutEffect(() => {
    const element = inner.current;
    if (!present || !element) return;
    const measure = () => setHeight(element.offsetHeight);
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(element);
    return () => observer.disconnect();
  }, [present]);
  // Its first frame draws at zero height, the next eases to the content's: it arrives, never pops.
  useEffect(() => {
    if (!present) {
      setArrived(false);
      return;
    }
    const frame = requestAnimationFrame(() => setArrived(true));
    return () => cancelAnimationFrame(frame);
  }, [present]);
  // Leaving: the last question stays until the height reaches zero, then goes in the same frame.
  useLayoutEffect(() => {
    if (leaving && !moving(outer.current)) setKept([]);
  }, [leaving]);
  if (drawn.length === 0 || !shown) return null;

  const step = (by: 1 | -1) => {
    const next = drawn[(index + by + drawn.length) % drawn.length];
    if (!next || next.id === shown.id) return;
    setDirection(by > 0 ? "next" : "previous");
    setShownId(next.id);
  };
  const send = (answer: HatAnswer) => {
    if (sending !== undefined) return;
    setSending(answer.id);
    setFailed(undefined);
    actions.answer(shown, answer).then(
      // Answered: the question leaves when its source says so; until then its buttons stay quiet.
      () => undefined,
      () => {
        setSending(undefined);
        setFailed(shown.id);
      },
    );
  };
  const folded = look === "chip" && !open;
  const dismiss = () => actions.dismiss(shown);
  // Escape while the focus is in the band puts the shown question away; a control that used it
  // first (a menu, a field) keeps it.
  const escapeKey = (event: React.KeyboardEvent<HTMLFieldSetElement>) => {
    if (folded || event.key !== "Escape" || event.defaultPrevented || event.nativeEvent.isComposing) return;
    event.preventDefault();
    dismiss();
  };
  const close = !folded && (
    <DismissButton
      className="acpmux-hat-questions__dismiss"
      label={t("message.dismiss")}
      reveal={dismissLook === "always" ? "always" : "hover"}
      onDismiss={dismiss}
    />
  );
  // A started chat's name has the head's line to itself, its question the line under it (not in the
  // one-line arm, which keeps everything on one line).
  const fromLine = Boolean(shown.who) && look !== "line";
  const prompt = (
    <span className="acpmux-hat-questions__prompt" title={shown.prompt}>
      {inlineText(shown.prompt)}
    </span>
  );
  const many = drawn.length > 1;
  // Left and right step through the questions from any of the band's buttons.
  const stepKeys = (event: React.KeyboardEvent<HTMLButtonElement>) => {
    if (!many || (event.key !== "ArrowLeft" && event.key !== "ArrowRight")) return;
    event.preventDefault();
    step(event.key === "ArrowRight" ? 1 : -1);
  };
  const pager = many && (
    <span className="acpmux-hat-questions__pager">
      <button
        type="button"
        onKeyDown={stepKeys}
        className="acpmux-hat-questions__step"
        data-step="previous"
        aria-label={t("hat.questions.previous")}
        title={t("hat.questions.previous")}
        onClick={() => step(-1)}
      >
        <Icon name="disclosure.collapsed" size={12} />
      </button>
      <span className="acpmux-hat-questions__position">
        {t("hat.questions.position", { n: index + 1, total: drawn.length })}
      </span>
      <button
        type="button"
        onKeyDown={stepKeys}
        className="acpmux-hat-questions__step"
        aria-label={t("hat.questions.next")}
        title={t("hat.questions.next")}
        onClick={() => step(1)}
      >
        <Icon name="disclosure.collapsed" size={12} />
      </button>
    </span>
  );
  const answers = (
    <div className="acpmux-hat-questions__answers">
      {shown.answers.map((answer) => (
        <button
          key={answer.id}
          type="button"
          onKeyDown={stepKeys}
          className="acpmux-hat-questions__answer"
          data-sending={sending === answer.id || undefined}
          disabled={sending !== undefined}
          onClick={() => send(answer)}
        >
          {answer.key ? t(answer.key) : inlineText(answer.label)}
        </button>
      ))}
      {shown.source === "child" ? (
        <button
          type="button"
          onKeyDown={stepKeys}
          className="acpmux-hat-questions__quiet"
          onClick={() => actions.open(shown)}
        >
          {t("hat.questions.open")}
        </button>
      ) : shown.onCard ? (
        <button
          type="button"
          onKeyDown={stepKeys}
          className="acpmux-hat-questions__quiet"
          onClick={() => actions.showCard(shown)}
        >
          {t("hat.questions.answerBelow")}
        </button>
      ) : (
        shown.typed && (
          <button
            type="button"
            onKeyDown={stepKeys}
            className="acpmux-hat-questions__quiet"
            onClick={() => actions.type(shown)}
          >
            {t("hat.questions.type")}
          </button>
        )
      )}
    </div>
  );
  return (
    <div
      ref={outer}
      className="acpmux-hat-questions"
      data-look={look}
      data-folded={folded || undefined}
      data-leaving={leaving || undefined}
      data-settled={settled || undefined}
      data-dismiss={dismissLook}
      style={{ "--acpmux-hat-questions-height": `${arrived && !leaving ? height : 0}px` } as CSSProperties}
      onTransitionEnd={(event) => {
        if (leaving && event.target === event.currentTarget) setKept([]);
      }}
      onTransitionCancel={(event) => {
        if (leaving && event.target === event.currentTarget) setKept([]);
      }}
    >
      <div ref={inner} className="acpmux-hat-questions__room">
        {/* oxlint-disable-next-line jsx-a11y/no-noninteractive-element-interactions -- Escape puts the shown question away from any of its buttons. */}
        <fieldset
          className="acpmux-hat-questions__body"
          aria-label={t("hat.questions")}
          data-dismiss-host=""
          onKeyDown={escapeKey}
        >
          {folded ? (
            <button type="button" className="acpmux-hat-questions__chip" onClick={() => setOpen(true)}>
              <span className="acpmux-hat-questions__mark" aria-hidden="true" />
              <span>{t("hat.questions.position", { n: index + 1, total: drawn.length })}</span>
              <Icon name="disclosure.expanded" size={12} />
            </button>
          ) : (
            <div key={shown.id} className="acpmux-hat-questions__question" data-direction={direction}>
              <div className="acpmux-hat-questions__head">
                <span className="acpmux-hat-questions__mark" aria-hidden="true" />
                {shown.tag && <span className="acpmux-hat-questions__tag">{t(TAG_KEY[shown.tag])}</span>}
                {shown.who && (
                  <span className="acpmux-hat-questions__who" data-line={fromLine || undefined} title={shown.who}>
                    {shown.who}
                  </span>
                )}
                {!fromLine && prompt}
                {look === "line" && answers}
                {pager}
                {close}
              </div>
              {fromLine && <div className="acpmux-hat-questions__under">{prompt}</div>}
              {look !== "line" && shown.detail && (
                <p className="acpmux-hat-questions__detail">{inlineText(shown.detail)}</p>
              )}
              {look !== "line" && answers}
              {failed === shown.id && (
                <p className="acpmux-hat-questions__failed" role="alert">
                  {t("question.replyFailed")}
                </p>
              )}
            </div>
          )}
        </fieldset>
      </div>
    </div>
  );
}
