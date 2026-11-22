import React, { useEffect, useId, useRef, useState } from "react";
import { flushSync } from "react-dom";
import { COMPOSER_READY_EVENT } from "../composerFocus";
import { Check } from "../conversation/icons";
import { useT, type Translate } from "../i18n";
import { Keycap } from "../Keycap";
import {
  activeItem,
  canSubmit,
  cardAnswer,
  cardState,
  highlightedRow,
  isChosen,
  isOtherRow,
  sendCard,
  updateCard,
  type CardEffect,
  type CardInput,
  type CardState,
} from "./cardState";
import {
  declineReply,
  hasPreviews,
  itemAnswerText,
  QuestionProblemError,
  questionSummary,
  reply,
  type AgentQuestion,
  type Answer,
  type QuestionReply,
} from "./model";

/// The keys a pending card answers while focus is inside it (the AgentQuestionCardState inputs).
/// Arrow keys may repeat; a held digit, Enter or Space answers once.
function inputForKey(key: string): CardInput | undefined {
  if (/^[1-9]$/.test(key)) return { type: "number", value: Number(key) };
  switch (key) {
    case "ArrowUp":
      return { type: "up" };
    case "ArrowDown":
      return { type: "down" };
    case "ArrowLeft":
      return { type: "previousItem" };
    case "ArrowRight":
      return { type: "nextItem" };
    case "Enter":
      return { type: "confirm" };
    case " ":
      return { type: "toggle" };
    case "Escape":
      return { type: "escape" };
    default:
      return undefined;
  }
}

const REPEATS = new Set(["ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight"]);

/// An agent's question (Claude Code AskUserQuestion, Codex user input, an interactive ACP
/// permission, the Chief) as a card: numbered options, checkmarks for multi-select, a preview of
/// the highlighted option, an inline Other answer, Submit and Skip. Bare keys work while focus is
/// inside the card; it never takes focus on arrival, and Escape hands the keyboard back to the
/// composer. Only a person's click or key sends an answer.
export function QuestionCard({ question, onReply }: { question: AgentQuestion; onReply(reply: QuestionReply): void }) {
  if (question.state.kind === "answered")
    return <AnsweredQuestion question={question} answer={question.state.answer} />;
  if (question.state.kind === "cancelled") return <CancelledQuestion question={question} />;
  return <PendingQuestion question={question} onReply={onReply} />;
}

// The rows are buttons with radio or checkbox roles (a radiogroup or group), not native inputs:
// one roving tab stop and the reducer's keys drive them, and the Other row turns into a text field
// in place. aria-checked carries the choice.
function PendingQuestion({ question, onReply }: { question: AgentQuestion; onReply(reply: QuestionReply): void }) {
  const t = useT();
  const legendId = useId();
  const previewId = useId();
  const group = useRef<HTMLFieldSetElement>(null);
  const [stored, setStored] = useState(() => cardState(question));
  // The ask a person already answered: the owner clears it a moment later, and until then a
  // second click or key must not answer it again.
  const [sentFor, setSentFor] = useState<string | undefined>();
  // A new snapshot of the same ask keeps the person's choices; another ask starts fresh.
  let state = stored;
  if (stored.question !== question) {
    state = stored.question.id === question.id ? updateCard(stored, question) : cardState(question);
    setStored(state);
  }
  const sent = sentFor === question.id;
  const item = activeItem(state);
  const highlighted = highlightedRow(state, item);

  const send = (sentReply: QuestionReply | undefined) => {
    if (!sentReply || sent) return;
    setSentFor(question.id);
    onReply(sentReply);
  };
  const apply = (effect: CardEffect, next: CardState, input: CardInput, keyboardInList: boolean) => {
    const card = group.current;
    if (effect.type === "submit") {
      try {
        send(reply(question, effect.answer));
      } catch (error) {
        if (!(error instanceof QuestionProblemError)) throw error;
      }
      return;
    }
    if (effect.type === "resign") {
      const focused = card?.ownerDocument.activeElement;
      if (focused instanceof HTMLElement && card?.contains(focused)) focused.blur();
      // The composer claims an idle keyboard on this event (composerFocus.ts).
      const view = card?.ownerDocument.defaultView ?? window;
      view.dispatchEvent(new view.Event(COMPOSER_READY_EVENT));
      return;
    }
    if (!card) return;
    // Focus follows the highlight (a roving tab stop) while the keyboard is in the list, and a
    // clicked row takes it so its keys work next; the Other field takes it while editing.
    if (next.editingOther) card.querySelector<HTMLInputElement>(".acpmux-question-other input")?.focus();
    else if (keyboardInList || input.type === "click")
      card.querySelector<HTMLElement>(`[data-row="${highlightedRow(next)}"]`)?.focus();
  };
  const dispatch = (input: CardInput) => {
    if (sent) return;
    const step = sendCard(state, input);
    const card = group.current;
    const focused = card?.ownerDocument.activeElement;
    // Whether the keyboard is in the list or the Other field (it may unmount during the update).
    const inList = focused instanceof HTMLElement && focused.closest(".acpmux-question-rows") !== null;
    flushSync(() => setStored(step.state));
    apply(step.effect, step.state, input, inList || focused === card);
  };
  const onKeyDown = (event: KeyboardEvent) => {
    if (event.defaultPrevented || event.metaKey || event.ctrlKey || event.altKey || event.isComposing) return;
    const target = event.target as HTMLElement;
    // In the Other field, typing is text: only Enter and Escape act.
    if (target.closest(".acpmux-question-other")) {
      if (event.key !== "Enter" && event.key !== "Escape") return;
    } else if (
      target.closest(".acpmux-question-actions, .acpmux-question-tabs") &&
      !/^[1-9]$|^Escape$/.test(event.key)
    ) {
      return; // Enter and Space press the focused Submit, Skip or tab button.
    }
    if (event.shiftKey) return;
    const input = inputForKey(event.key);
    if (!input) return;
    event.preventDefault();
    if (event.repeat && !REPEATS.has(event.key)) return;
    dispatch(input);
  };
  // The keys reach the card from its focused rows, field and buttons, so it listens natively
  // (PermissionCard does the same): the fieldset is a group, not a control of its own. It runs
  // before the composer's document listener, which skips a key the card prevented.
  useEffect(() => {
    const element = group.current;
    if (!element) return;
    // ui-allow: the keys are the shared AgentQuestionCardState inputs (number keys, a roving highlight, items), which no src/ui widget offers; the Mac card answers the same keys.
    element.addEventListener("keydown", onKeyDown);
    return () => element.removeEventListener("keydown", onKeyDown);
  });
  const goToItem = (index: number) => {
    let next = state;
    while (next.activeItem !== index) {
      const step = sendCard(next, { type: index > next.activeItem ? "nextItem" : "previousItem" });
      if (step.state.activeItem === next.activeItem) break;
      next = step.state;
    }
    setStored(next);
  };

  if (!item) return null;
  const previewOption = item.options[highlighted] ?? item.options.find((option) => option.preview);
  const showPreview = hasPreviews(item);
  const multi = item.multiSelect;
  const draft = state.otherDrafts[item.id] ?? "";
  const ready = canSubmit(state) && !sent;
  const agent = question.source.agentName ?? t("question.agent");
  const answer = state.question.items.length > 1 ? cardAnswer(state) : undefined;
  return (
    <fieldset
      ref={group}
      className="acpmux-question"
      aria-labelledby={legendId}
      aria-busy={sent || undefined}
      data-preview={showPreview || undefined}
    >
      <legend id={legendId} className="acpmux-question-head">
        <span className="acpmux-question-meta">
          {item.header && <span className="acpmux-question-chip">{item.header}</span>}
          <span className="acpmux-question-agent">{t("question.asking", { agent })}</span>
        </span>
        <span className="acpmux-question-prompt">{item.prompt}</span>
      </legend>
      {state.question.items.length > 1 && (
        <div className="acpmux-question-tabs">
          {state.question.items.map((each, index) => (
            <button
              key={each.id}
              type="button"
              className="acpmux-question-tab"
              aria-current={index === state.activeItem ? "step" : undefined}
              data-answered={(answer && itemAnswerText(each, answer) !== "") || undefined}
              aria-label={t("question.step", { n: index + 1, count: state.question.items.length })}
              title={each.header ?? each.prompt}
              onClick={() => goToItem(index)}
            >
              {each.header ?? index + 1}
            </button>
          ))}
        </div>
      )}
      <div className="acpmux-question-body">
        <div className="acpmux-question-rows" role={multi ? "group" : "radiogroup"} aria-labelledby={legendId}>
          {item.options.map((option, row) => {
            const chosen = isChosen(state, option, item);
            const key = row < 9 ? String(row + 1) : undefined;
            return (
              <button
                key={option.id}
                type="button"
                className="acpmux-question-row"
                role={multi ? "checkbox" : "radio"}
                aria-checked={chosen}
                aria-keyshortcuts={key}
                aria-disabled={sent || undefined}
                data-row={row}
                data-highlighted={row === highlighted || undefined}
                // ui-allow: the roving tab stop follows the reducer's highlighted row (radio and checkbox rows alike).
                tabIndex={row === highlighted ? 0 : -1}
                onClick={() => dispatch({ type: "click", row })}
              >
                {key ? <Keycap>{key}</Keycap> : <span className="acpmux-question-keyspace" />}
                <span className="acpmux-question-text">
                  <span className="acpmux-question-label">{option.label}</span>
                  {option.detail && <span className="acpmux-question-detail">{option.detail}</span>}
                </span>
                <span className="acpmux-question-mark" data-multi={multi || undefined}>
                  {chosen && <Check size={14} strokeWidth={1.6} />}
                </span>
              </button>
            );
          })}
          {item.allowsOther && (
            <OtherRow
              t={t}
              row={item.options.length}
              editing={state.editingOther}
              draft={draft}
              multi={multi}
              highlighted={isOtherRow(highlighted, item)}
              chosen={draft.trim() !== ""}
              disabled={sent}
              onChoose={() => dispatch({ type: "click", row: item.options.length })}
              onText={(text) => dispatch({ type: "otherText", text })}
            />
          )}
        </div>
        {showPreview && previewOption && (
          <section className="acpmux-question-preview" aria-labelledby={previewId}>
            <span id={previewId} className="acpmux-question-preview-label">
              {t("question.preview", { option: previewOption.label })}
            </span>
            <pre>{previewOption.preview?.text ?? ""}</pre>
          </section>
        )}
      </div>
      <div className="acpmux-question-actions">
        <button
          type="button"
          className="acpmux-question-skip"
          disabled={sent}
          onClick={() => send(declineReply(question))}
        >
          {t("question.skip")}
        </button>
        <button
          type="button"
          className="acpmux-question-submit"
          disabled={!ready}
          onClick={() => dispatch({ type: "submit" })}
        >
          {t("question.submit")}
          <Keycap>↩</Keycap>
        </button>
      </div>
    </fieldset>
  );
}

/// The "Other" row: a row like the options until chosen, then an inline text field.
function OtherRow({
  t,
  row,
  editing,
  draft,
  multi,
  highlighted,
  chosen,
  disabled,
  onChoose,
  onText,
}: {
  t: Translate;
  row: number;
  editing: boolean;
  draft: string;
  multi: boolean;
  highlighted: boolean;
  chosen: boolean;
  disabled: boolean;
  onChoose(): void;
  onText(text: string): void;
}) {
  const key = row < 9 ? String(row + 1) : undefined;
  if (editing)
    return (
      <div className="acpmux-question-row acpmux-question-other" data-row-editing="true" data-highlighted>
        {key ? <Keycap>{key}</Keycap> : <span className="acpmux-question-keyspace" />}
        <input
          type="text"
          aria-label={t("question.other")}
          placeholder={t("question.otherPlaceholder")}
          value={draft}
          disabled={disabled}
          onChange={(event) => onText(event.currentTarget.value)}
        />
      </div>
    );
  return (
    <button
      type="button"
      className="acpmux-question-row acpmux-question-other-choice"
      role={multi ? "checkbox" : "radio"}
      aria-checked={chosen}
      aria-keyshortcuts={key}
      aria-disabled={disabled || undefined}
      data-row={row}
      data-highlighted={highlighted || undefined}
      // ui-allow: the roving tab stop follows the reducer's highlighted row.
      tabIndex={highlighted ? 0 : -1}
      onClick={onChoose}
    >
      {key ? <Keycap>{key}</Keycap> : <span className="acpmux-question-keyspace" />}
      <span className="acpmux-question-text">
        <span className="acpmux-question-label">{t("question.other")}</span>
        {chosen && <span className="acpmux-question-detail">{draft.trim()}</span>}
      </span>
      <span className="acpmux-question-mark" data-multi={multi || undefined}>
        {chosen && <Check size={14} strokeWidth={1.6} />}
      </span>
    </button>
  );
}

/// Who answered and where, when the owner says: "Answered by Lawrence on Lawrence's iPhone".
function respondentLine(t: Translate, answer: Answer): string | undefined {
  const name = answer.respondent?.displayName;
  const device = answer.respondent?.device;
  if (name && device) return t("question.answeredBy", { name, device });
  if (name) return t("question.answeredByName", { name });
  if (device) return t("question.answeredOn", { device });
  return undefined;
}

/// An answered ask collapses to one row: a check, "header: chosen labels" per item, and who
/// answered on which device.
function AnsweredQuestion({ question, answer }: { question: AgentQuestion; answer: Answer }) {
  const t = useT();
  const by = respondentLine(t, answer);
  return (
    <div className="acpmux-question-answered" data-remote={answer.respondent?.isRemote || undefined}>
      <span className="acpmux-question-answered-icon">
        <Check size={14} strokeWidth={1.6} />
      </span>
      <span className="acpmux-hidden-label">{t("question.answered")}</span>
      <span className="acpmux-question-answered-lines">
        {question.items.map((item) => (
          <span key={item.id} className="acpmux-question-answered-line">
            <span className="acpmux-question-answered-key">{item.header ?? item.prompt}:</span>{" "}
            {itemAnswerText(item, answer)}
          </span>
        ))}
      </span>
      {by && <span className="acpmux-question-answered-by">{by}</span>}
    </div>
  );
}

function CancelledQuestion({ question }: { question: AgentQuestion }) {
  const t = useT();
  return (
    <div className="acpmux-question-cancelled">{t("question.cancelled", { prompt: questionSummary(question) })}</div>
  );
}
