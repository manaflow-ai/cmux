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
// A question a chat this one started asks is answered here too, as its own card would answer it:
// who asks and what about on the first line, the whole question (two lines, then More), its choices
// as buttons with the agent's recommended one marked, and a reply field for an answer in the
// person's own words; the host sends it for the chat this pane does not show. Open Chat stays for
// the rest. Leo, 2026-11-10: "this is unusable to respond to i necessarily have to open... this is
// bad ui".
import React, { type CSSProperties, useEffect, useLayoutEffect, useRef, useState } from "react";
import { experimentArm } from "../../../experiments/experiment";
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
  /// Sends an answer in the person's own words (the question's Other) to a started chat's question;
  /// rejects when it was refused, and the field keeps the text.
  reply(question: HatQuestion, text: string): Promise<unknown>;
  /// Puts the cursor in the composer: what the person types there answers it (and withdraws a
  /// waiting question, App.tsx `withdrawForTypedReply`).
  type(question: HatQuestion): void;
  /// Brings the question's full card into view (one that needs more than a click).
  showCard(question: HatQuestion): void;
  /// Opens a started chat's question in its chat.
  open(question: HatQuestion): void;
};

/// The `sending` mark of a typed reply (an answer's is its id).
const REPLY = "\u0000reply";

/// Whether the band's height transition is still running; with motion off it never starts.
const moving = (element: HTMLElement | null) =>
  element?.getAnimations().some((animation) => animation.playState === "running") ?? false;

/// Where a started chat's question puts its reply field (the gallery compares them): on its own line
/// under the choices (shipped), at the end of the choices' line, or behind a Reply button.
export type HatReplyLook = "below" | "inline" | "reveal";

export function HatQuestions({
  questions,
  actions,
  look: lookProp,
  replyLook = "below",
}: {
  questions: readonly HatQuestion[];
  actions: HatQuestionActions;
  /// The gallery's arm; the pane reads the experiment.
  look?: "band" | "line" | "chip";
  replyLook?: HatReplyLook;
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
  // The reply field's text, its reveal (the `reveal` look) and whether the whole question shows.
  const [draft, setDraft] = useState("");
  const [replying, setReplying] = useState(false);
  const [whole, setWhole] = useState(false);
  // A new question shown is a new chance to answer: the last one's state goes.
  useEffect(() => {
    setSending(undefined);
    setFailed(undefined);
    setDraft("");
    setReplying(false);
    setWhole(false);
  }, [shown?.id]);
  // Revealed by a click (the `reveal` look), the field takes the cursor; drawn from the start, it
  // waits for one.
  const fieldRef = useRef<HTMLInputElement>(null);
  useEffect(() => {
    if (replying) fieldRef.current?.focus({ preventScroll: true });
  }, [replying]);
  // Whether the question runs past its two lines: only then is there a More to offer.
  const promptRef = useRef<HTMLSpanElement>(null);
  const [overflows, setOverflows] = useState(false);
  useLayoutEffect(() => {
    const element = promptRef.current;
    if (!element || whole) return;
    const measure = () => setOverflows(element.scrollHeight > element.clientHeight + 1);
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(element);
    return () => observer.disconnect();
  }, [shown?.id, shown?.prompt, whole]);

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
      // Opened in its chat instead: the band takes a click again.
      (outcome) => {
        if (outcome === "opened") setSending(undefined);
      },
      () => {
        setSending(undefined);
        setFailed(shown.id);
      },
    );
  };
  const sendReply = (event?: React.FormEvent) => {
    event?.preventDefault();
    const text = draft.trim();
    if (!text || sending !== undefined) return;
    setSending(REPLY);
    setFailed(undefined);
    actions.reply(shown, text).then(
      (outcome) => {
        if (outcome === "opened") setSending(undefined);
      },
      () => {
        setSending(undefined);
        setFailed(shown.id);
      },
    );
  };
  const folded = look === "chip" && !open;
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
  // A started chat's question that takes an answer in the person's own words: the field, which
  // only a click on Send sends (the host answers another chat on the person's click alone).
  const replies = shown.source === "child" && shown.typed && look !== "line";
  const fieldShown = replies && (replyLook !== "reveal" || replying);
  const field = fieldShown && (
    <form className="acpmux-hat-questions__reply" data-reply={replyLook} onSubmit={(event) => event.preventDefault()}>
      <input
        className="acpmux-hat-questions__field"
        value={draft}
        placeholder={t("hat.questions.replyPlaceholder")}
        aria-label={t("hat.questions.replyPlaceholder")}
        ref={fieldRef}
        disabled={sending !== undefined}
        onChange={(event) => setDraft(event.target.value)}
      />
      <button
        type="button"
        className="acpmux-hat-questions__send"
        data-sending={sending === REPLY || undefined}
        disabled={!draft.trim() || sending !== undefined}
        onClick={() => sendReply()}
      >
        {t("composer.send")}
      </button>
    </form>
  );
  const answers = (
    <div className="acpmux-hat-questions__answers">
      {shown.answers.map((answer) => (
        <button
          key={answer.id}
          type="button"
          onKeyDown={stepKeys}
          className="acpmux-hat-questions__answer"
          data-recommended={answer.recommended || undefined}
          data-sending={sending === answer.id || undefined}
          disabled={sending !== undefined}
          onClick={() => send(answer)}
        >
          {answer.key ? t(answer.key) : inlineText(answer.label)}
          {answer.recommended && (
            <span className="acpmux-hat-questions__recommended">{t("hat.questions.recommended")}</span>
          )}
        </button>
      ))}
      {replyLook === "inline" && field}
      {replies && replyLook === "reveal" && !replying && (
        <button
          type="button"
          onKeyDown={stepKeys}
          className="acpmux-hat-questions__quiet"
          disabled={sending !== undefined}
          onClick={() => setReplying(true)}
        >
          {t("hat.questions.reply")}
        </button>
      )}
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
  // A started chat's question names who asks and what about on its own first line, so the question
  // under it has the band's whole width; the chat's own keep the question on that line.
  const asker = look !== "line" && Boolean(shown.who || shown.about);
  const prompt = (
    <span className="acpmux-hat-questions__words">
      <span
        ref={promptRef}
        className="acpmux-hat-questions__prompt"
        data-whole={whole || undefined}
        title={shown.prompt}
      >
        {inlineText(shown.prompt)}
      </span>
      {look !== "line" && (overflows || whole) && (
        <button
          type="button"
          onKeyDown={stepKeys}
          className="acpmux-hat-questions__more"
          aria-expanded={whole}
          onClick={() => setWhole((value) => !value)}
        >
          {t(whole ? "message.less" : "message.more")}
        </button>
      )}
    </span>
  );
  return (
    <div
      ref={outer}
      className="acpmux-hat-questions"
      data-look={look}
      data-folded={folded || undefined}
      data-leaving={leaving || undefined}
      data-settled={settled || undefined}
      style={{ "--acpmux-hat-questions-height": `${arrived && !leaving ? height : 0}px` } as CSSProperties}
      onTransitionEnd={(event) => {
        if (leaving && event.target === event.currentTarget) setKept([]);
      }}
      onTransitionCancel={(event) => {
        if (leaving && event.target === event.currentTarget) setKept([]);
      }}
    >
      <div ref={inner} className="acpmux-hat-questions__room">
        <fieldset className="acpmux-hat-questions__body" aria-label={t("hat.questions")}>
          {folded ? (
            <button type="button" className="acpmux-hat-questions__chip" onClick={() => setOpen(true)}>
              <span className="acpmux-hat-questions__mark" aria-hidden="true" />
              <span>{t("hat.questions.position", { n: index + 1, total: drawn.length })}</span>
              <Icon name="disclosure.expanded" size={12} />
            </button>
          ) : (
            <div
              key={shown.id}
              className="acpmux-hat-questions__question"
              data-direction={direction}
              data-asker={asker || undefined}
            >
              <div className="acpmux-hat-questions__head">
                <span className="acpmux-hat-questions__mark" aria-hidden="true" />
                {shown.tag && <span className="acpmux-hat-questions__tag">{t(TAG_KEY[shown.tag])}</span>}
                {shown.who && <span className="acpmux-hat-questions__who">{shown.who}</span>}
                {shown.about && <span className="acpmux-hat-questions__about">{inlineText(shown.about)}</span>}
                {!asker && prompt}
                {look === "line" && answers}
                {pager}
              </div>
              {asker && prompt}
              {look !== "line" && shown.detail && (
                <p className="acpmux-hat-questions__detail">{inlineText(shown.detail)}</p>
              )}
              {look !== "line" && answers}
              {replyLook !== "inline" && field}
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
