import React, { useEffect, useId, useRef, useState } from "react";
import { flushSync } from "react-dom";
import { experimentArm } from "../../../experiments/experiment";
import { COMPOSER_READY_EVENT } from "../composerFocus";
import { Check, ChevronDown } from "../conversation/icons";
import { usePaneLanguage, useT, type Translate } from "../i18n";
import { Keycap } from "../Keycap";
import { NativeError } from "../nativeError";
import { errorMessage, isHostRefusal } from "../transportErrors";
import {
  activeItem,
  canSubmit,
  cardAnswer,
  cardState,
  highlightedRow,
  isChosen,
  isOtherRow,
  primaryAction,
  sendCard,
  unansweredItems,
  updateCard,
  type CardEffect,
  type CardInput,
  type CardState,
} from "./cardState";
import { HtmlPreview } from "./HtmlPreview";
import { inlineText, plainText } from "./inlineText";
import {
  declineReply,
  hasPreviews,
  itemAnswerText,
  QuestionProblemError,
  cancelledKey,
  reply,
  type AgentQuestion,
  type Answer,
  type Option,
  type QuestionReply,
} from "./model";
import { cancelledArgs } from "./record";
import { questionPreviewLayout, type QuestionPreviewLayout } from "./previewLayout.experiment";

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
/// permission, the Chief) as a card, like the Claude app's (Leo 2026-10-19): a "Needs your input"
/// pill that folds it, the question as its header, radio or checkbox options with their
/// descriptions, a preview of the highlighted option, an inline Other answer, Skip and Submit. An
/// ask of several questions says Next while another question is still open, and a Submit that
/// cannot send yet names the questions it waits for ("Answer References to submit").
/// Bare keys work while focus is inside the card, and it takes the keyboard on arrival only when
/// nothing else has it or the composer is empty. A click chooses an option and never sends it (Leo,
/// 2026-10-24: "just clicking it directly just automatically sends the input. So it makes the skip
/// and submit buttons redundant"): Submit or ⌘↩ sends, Enter sends the highlighted row, and a
/// double-click on a single-choice option chooses and sends it. Escape never answers (plans/cmux-next/agent-questions.md §6):
/// it hands the keyboard back to the composer and keeps every answer given so far, so the next Esc
/// is the composer's (on an empty prompt, the press that stops a turn). The card leaves the key to
/// the pane's own listeners, except in the floating chat, where an Esc nobody claimed hides the
/// panel. In the Other field it only leaves the field. Skip
/// declines. A reply acpmux refuses shows its error on the card, which takes input again for a
/// retry. Only a person's click or key sends an answer.
export function QuestionCard({ question, onReply }: { question: AgentQuestion; onReply: ReplyHandler }) {
  if (question.state.kind === "answered")
    return <AnsweredQuestion question={question} answer={question.state.answer} />;
  if (question.state.kind === "cancelled") return <CancelledQuestion question={question} />;
  // Keyed by the ask: a new ask starts unfolded with fresh choices.
  return <PendingAsk key={question.id} question={question} onReply={onReply} />;
}

/// Hands the host a reply. A promise that rejects means the reply was refused and the ask stays.
type ReplyHandler = (reply: QuestionReply) => void | Promise<unknown>;

/// The pill over a pending card. Folding hides the card but keeps it mounted, so the person's
/// picks and Other text survive; the ask stays pending until answered or skipped.
function PendingAsk({ question, onReply }: { question: AgentQuestion; onReply: ReplyHandler }) {
  const t = useT();
  const cardId = useId();
  const [open, setOpen] = useState(true);
  return (
    <div className="acpmux-question-ask">
      <button
        type="button"
        className="acpmux-question-status"
        aria-expanded={open}
        aria-controls={cardId}
        onClick={() => setOpen((shown) => !shown)}
      >
        <span className="acpmux-question-status-dot" aria-hidden="true" />
        {t("question.needsInput")}
        <ChevronDown size={12} strokeWidth={1.6} className="acpmux-question-status-chevron" />
      </button>
      <PendingQuestion id={cardId} hidden={!open} question={question} onReply={onReply} />
    </div>
  );
}

/// The prompt's typed text, without the placeholder MarkdownField keeps beside the editor.
const composerText = (composer: Element) => composer.querySelector(".acpmux-md-root")?.textContent?.trim() ?? "";

/// A refused reply's message when it is already in the person's language: the app's reply
/// (NativeError's userMessage) or the pane's own words for a lost or timed-out request
/// (`native.*`, direct.ts). Any other message is acpmux's English, meant for its CLI.
function localizedMessage(error: unknown): string | undefined {
  if (!(error instanceof Error) || !error.message) return undefined;
  const { code } = error as { code?: unknown };
  const local = error instanceof NativeError || (typeof code === "string" && code.startsWith("native."));
  return local ? error.message : undefined;
}

/// Whether a card that just arrived may take the keyboard: nothing in the page has it, or the
/// composer has it, and either way the composer holds no draft. A half-written (or restored)
/// prompt keeps it, so a typed digit or Enter never answers the ask by surprise.
function keyboardIsIdle(document: Document): boolean {
  const active = document.activeElement;
  if (!active || active === document.body) {
    const composer = document.querySelector(".acpmux-composer-prompt");
    const shell = document.querySelector<HTMLTextAreaElement>(".acpmux-shell-field");
    return (!composer || composerText(composer) === "") && !shell?.value.trim();
  }
  const composer = active.closest(".acpmux-composer-prompt");
  return composer !== null && composerText(composer) === "";
}

// The rows are buttons with radio or checkbox roles (a radiogroup or group), not native inputs:
// one roving tab stop and the reducer's keys drive them, and the Other row turns into a text field
// in place. aria-checked carries the choice.
function PendingQuestion({
  id,
  hidden,
  question,
  onReply,
}: {
  id: string;
  hidden: boolean;
  question: AgentQuestion;
  onReply: ReplyHandler;
}) {
  const t = useT();
  const legendId = useId();
  const previewId = useId();
  const hintId = useId();
  const language = usePaneLanguage();
  const listFormat = new Intl.ListFormat(language, { type: "conjunction" });
  const group = useRef<HTMLFieldSetElement>(null);
  const [stored, setStored] = useState(() => cardState(question));
  // The ask a person already answered: the owner clears it a moment later, and until then a
  // second click or key must not answer it again. A refused reply clears it for a retry.
  const [sentFor, setSentFor] = useState<string | undefined>();
  // The last reply's refusal, shown until the next try: the card's sentence, then the pane's words
  // for a refusal it knows (transportErrors.ts) or a message already in the person's language (the
  // app's or the pane's own). acpmux's English is for its CLI.
  const [refused, setRefused] = useState<{ reason?: string } | undefined>();
  // The row under the pointer: its preview shows while it is hovered, then the highlighted row's.
  const [hovered, setHovered] = useState<{ item: string; row: number } | undefined>();
  // Where the preview draws (previewLayout.experiment.ts); read once per card.
  const [layout] = useState<QuestionPreviewLayout>(() => experimentArm(questionPreviewLayout));
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
    setRefused(undefined);
    const askId = question.id;
    Promise.resolve(onReply(sentReply)).catch((error: unknown) => {
      // The ask stays pending: say why on the card and take input again.
      setSentFor((current) => (current === askId ? undefined : current));
      if (isHostRefusal(error)) {
        setRefused({ reason: errorMessage(error) });
        return;
      }
      const reason = localizedMessage(error);
      if (reason) setRefused({ reason });
      else {
        console.warn("agent pane: an answer was refused", error);
        setRefused({});
      }
    });
  };
  /// Gives the keyboard back: the composer claims an idle keyboard on this event (composerFocus.ts).
  const resign = () => {
    const card = group.current;
    const focused = card?.ownerDocument.activeElement;
    if (focused instanceof HTMLElement && card?.contains(focused)) focused.blur();
    const view = card?.ownerDocument.defaultView ?? window;
    view.dispatchEvent(new view.Event(COMPOSER_READY_EVENT));
  };
  const skip = () => {
    if (sent) return;
    send(declineReply(question));
    resign();
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
      resign();
      return;
    }
    if (!card) return;
    // Focus follows the highlight (a roving tab stop) while the keyboard is in the list, and a
    // clicked row takes it so its keys work next; the Other field takes it while editing.
    if (next.editingOther) card.querySelector<HTMLInputElement>(".acpmux-question-other input")?.focus();
    else if (keyboardInList || input.type === "click" || input.type === "next")
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
    // WebKit sends the Enter that commits an IME candidate after compositionend, as keyCode 229.
    if (event.defaultPrevented || event.isComposing || event.keyCode === 229) return;
    // ⌘↩ submits from anywhere in the card, the Other field included. With nothing chosen yet it
    // answers like Enter: the highlighted row, then Submit once every item has an answer.
    if (event.key === "Enter" && event.metaKey && !event.ctrlKey && !event.altKey && !event.shiftKey) {
      event.preventDefault();
      if (!event.repeat) dispatch(canSubmit(state) ? { type: "submit" } : { type: "confirm" });
      return;
    }
    if (event.metaKey || event.ctrlKey || event.altKey) return;
    const target = event.target as HTMLElement;
    const inOther = target.closest(".acpmux-question-other") !== null;
    // In the Other field, typing is text: only Enter and Escape act.
    if (inOther) {
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
    // Escape never answers. Outside the Other field it hands the keyboard to the composer (in one
    // press, even with an Other answer left open) and keeps every answer. The key is left to the
    // pane's own listeners, except in the floating chat: there an Esc nobody claimed hides the
    // panel (paneSurface.ts useEscapeToDismiss, QuickComposerPanel.cancelOperation).
    if (input.type === "escape" && !inOther) {
      if (target.closest('[data-surface="quick"]')) event.preventDefault();
      if (!event.repeat) resign();
      return;
    }
    event.preventDefault();
    if (event.repeat && !REPEATS.has(event.key)) return;
    // In the Other field the reducer's Escape only leaves the field.
    dispatch(input);
  };
  // The keys reach the card from its focused rows, field and buttons, so it listens natively:
  // the fieldset is a group, not a control of its own. It runs
  // before the composer's document listener, which skips a key the card prevented.
  useEffect(() => {
    const element = group.current;
    if (!element) return;
    // ui-allow: the keys are the shared AgentQuestionCardState inputs (number keys, a roving highlight, items), which no src/ui widget offers; the Mac card answers the same keys.
    element.addEventListener("keydown", onKeyDown);
    return () => element.removeEventListener("keydown", onKeyDown);
  });
  // A new ask takes an idle keyboard, so its keys work without a click first. Only on arrival:
  // later snapshots of the same ask leave focus where the person put it.
  const arrived = useRef<string | undefined>(undefined);
  useEffect(() => {
    const card = group.current;
    if (!card || arrived.current === question.id) return;
    arrived.current = question.id;
    if (hidden || !keyboardIsIdle(card.ownerDocument)) return;
    card.querySelector<HTMLElement>(`[data-row="${highlightedRow(state)}"]`)?.focus();
  });
  const goToItem = (index: number) => {
    let next = state;
    while (next.activeItem !== index) {
      const step = sendCard(next, { type: index > next.activeItem ? "nextItem" : "previousItem" });
      if (step.state.activeItem === next.activeItem) break;
      next = step.state;
    }
    flushSync(() => setStored(next));
    // The keyboard goes to that question's rows, so its arrows and Return answer it (the card
    // leaves both keys to a focused tab button).
    group.current?.querySelector<HTMLElement>(`[data-row="${highlightedRow(next)}"]`)?.focus();
  };

  if (!item) return null;
  const hoveredRow = hovered?.item === item.id ? hovered.row : undefined;
  const previewOption = shownPreview(item.options, [hoveredRow, highlighted]);
  const showPreview = hasPreviews(item);
  const preview = showPreview && previewOption && (
    <OptionPreview id={previewId} t={t} option={previewOption} inline={layout === "inline"} />
  );
  const multi = item.multiSelect;
  const draft = state.otherDrafts[item.id] ?? "";
  const ready = canSubmit(state) && !sent;
  // The primary button says what it does: Next while another question is still open, else Submit.
  // A Submit that cannot send yet names the questions it waits for, so it is never a silent pill.
  const action = primaryAction(state);
  const waitingFor =
    action === "submit" && !ready && !sent && state.question.items.length > 1
      ? unansweredItems(state).map((index) => {
          const each = state.question.items[index]!;
          return each.header ?? t("question.step", { n: index + 1, count: state.question.items.length });
        })
      : [];
  const agent = question.source.agentName ?? t("question.agent");
  const answer = state.question.items.length > 1 ? cardAnswer(state) : undefined;
  return (
    <fieldset
      ref={group}
      id={id}
      hidden={hidden}
      className="acpmux-question"
      aria-labelledby={legendId}
      aria-busy={sent || undefined}
      data-preview={showPreview || undefined}
      data-preview-layout={showPreview ? layout : undefined}
    >
      <legend id={legendId} className="acpmux-question-head">
        <span className="acpmux-hidden-label">{t("question.asking", { agent })}</span>
        <span className="acpmux-question-prompt">{inlineText(item.prompt)}</span>
        {item.header && <span className="acpmux-question-chip">{item.header}</span>}
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
              onClick={() => goToItem(index)}
            >
              {each.header ?? index + 1}
            </button>
          ))}
        </div>
      )}
      <div className="acpmux-question-body">
        <div
          className="acpmux-question-rows"
          role={multi ? "group" : "radiogroup"}
          aria-labelledby={legendId}
          onMouseLeave={() => setHovered(undefined)}
        >
          {item.options.map((option, row) => {
            const chosen = isChosen(state, option, item);
            const key = row < 9 ? String(row + 1) : undefined;
            return (
              <React.Fragment key={option.id}>
                <button
                  type="button"
                  className="acpmux-question-row"
                  data-focus-ring="row"
                  role={multi ? "checkbox" : "radio"}
                  aria-checked={chosen}
                  aria-keyshortcuts={key}
                  aria-disabled={sent || undefined}
                  data-row={row}
                  data-highlighted={row === highlighted || undefined}
                  // ui-allow: the roving tab stop follows the reducer's highlighted row (radio and checkbox rows alike).
                  tabIndex={row === highlighted ? 0 : -1}
                  onClick={() => dispatch({ type: "click", row })}
                  onDoubleClick={() => dispatch({ type: "doubleClick", row })}
                  onMouseEnter={() => setHovered({ item: item.id, row })}
                >
                  <ChoiceMark multi={multi} chosen={chosen} />
                  <span className="acpmux-question-text">
                    <span className="acpmux-question-label">{inlineText(option.label)}</span>
                    {option.detail && <span className="acpmux-question-detail">{inlineText(option.detail)}</span>}
                  </span>
                </button>
                {layout === "inline" && option === previewOption && preview}
              </React.Fragment>
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
              onHover={() => setHovered({ item: item.id, row: item.options.length })}
              onText={(text) => dispatch({ type: "otherText", text })}
            />
          )}
        </div>
        {layout !== "inline" && preview}
      </div>
      {refused && (
        <p className="acpmux-question-error" role="alert">
          {t("question.replyFailed")}
          {refused.reason && " "}
          {refused.reason && <span className="acpmux-question-error-reason">{refused.reason}</span>}
        </p>
      )}
      <div className="acpmux-question-actions">
        {waitingFor.length > 0 && (
          <span id={hintId} className="acpmux-question-hint">
            {t("question.answerToSubmit", { questions: listFormat.format(waitingFor) })}
          </span>
        )}
        <button type="button" className="acpmux-question-skip" disabled={sent} onClick={skip}>
          {t("question.skip")}
        </button>
        {action === "next" ? (
          <button
            type="button"
            className="acpmux-question-submit"
            data-action="next"
            disabled={sent}
            onClick={() => dispatch({ type: "next" })}
          >
            {t("question.next")}
          </button>
        ) : (
          <button
            type="button"
            className="acpmux-question-submit"
            aria-keyshortcuts="Meta+Enter"
            aria-describedby={waitingFor.length > 0 ? hintId : undefined}
            disabled={!ready}
            onClick={() => dispatch({ type: "submit" })}
          >
            {t("question.submit")}
            <Keycap>⌘↩</Keycap>
          </button>
        )}
      </div>
    </fieldset>
  );
}

/// The option whose preview shows: the first of `rows` (the hovered row, then the highlighted one)
/// that has a preview, else the first option with one. The Other row has none.
export function shownPreview(options: Option[], rows: (number | undefined)[]): Option | undefined {
  for (const row of rows) {
    const option = row === undefined ? undefined : options[row];
    if (option?.preview) return option;
  }
  return options.find((option) => option.preview);
}

/// A preview's text as Claude Code draws it, Markdown in a monospace box: an agent often wraps its
/// mockup or code in a fence, which the box stands for, so the fence lines go (a fence and its info
/// string alone on a line, never a line with an inline code span) and the rest keeps every space
/// and line break (ASCII mockups line up only that way).
export function previewText(text: string): string {
  return text
    .split("\n")
    .filter((line) => !/^\s*(`{3,}|~{3,})[^`~]*$/.test(line))
    .join("\n")
    .replace(/^\n+|\s+$/g, "");
}

/// The highlighted (or hovered) option's preview, labelled with its option. In the `inline` layout
/// it opens under that option's row.
function OptionPreview({ id, t, option, inline }: { id: string; t: Translate; option: Option; inline: boolean }) {
  return (
    <section
      className="acpmux-question-preview"
      data-inline={inline || undefined}
      data-format={option.preview?.format}
      aria-labelledby={id}
    >
      <span id={id} className="acpmux-question-preview-label">
        {t("question.preview", { option: plainText(option.label) })}
      </span>
      {option.preview?.format === "html" ? (
        <HtmlPreview html={option.preview.text} title={t("question.preview", { option: plainText(option.label) })} />
      ) : (
        <pre>{previewText(option.preview?.text ?? "")}</pre>
      )}
    </section>
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
  onHover,
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
  /// The pointer came onto the row: it has no preview, so the highlighted option's shows.
  onHover(): void;
  onText(text: string): void;
}) {
  const key = row < 9 ? String(row + 1) : undefined;
  if (editing)
    return (
      <div
        className="acpmux-question-row acpmux-question-other"
        data-row-editing="true"
        data-highlighted
        onMouseEnter={onHover}
      >
        <ChoiceMark multi={multi} chosen={multi ? draft.trim() !== "" : true} />
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
      data-focus-ring="row"
      role={multi ? "checkbox" : "radio"}
      aria-checked={chosen}
      aria-keyshortcuts={key}
      aria-disabled={disabled || undefined}
      data-row={row}
      data-highlighted={highlighted || undefined}
      // ui-allow: the roving tab stop follows the reducer's highlighted row.
      tabIndex={highlighted ? 0 : -1}
      onClick={onChoose}
      onMouseEnter={onHover}
    >
      <ChoiceMark multi={multi} chosen={chosen} />
      <span className="acpmux-question-text">
        <span className="acpmux-question-label">{t("question.other")}</span>
        {chosen && <span className="acpmux-question-detail">{draft.trim()}</span>}
      </span>
    </button>
  );
}

/// A row's radio button, or its checkbox when the item takes several answers. Decoration: the row
/// carries the role and aria-checked (the Other field, which has neither, still shows its mark).
function ChoiceMark({ multi, chosen }: { multi: boolean; chosen: boolean }) {
  return (
    <span
      className="acpmux-question-mark"
      data-multi={multi || undefined}
      data-chosen={chosen || undefined}
      aria-hidden="true"
    >
      {multi && chosen && <Check size={11} strokeWidth={2} />}
    </span>
  );
}

/// Who answered and where, when the owner says: "Answered by Lawrence on Lawrence's iPhone".
function respondentLine(t: Translate, answer: Answer): string | undefined {
  const name = answer.respondent?.displayName;
  const device = answer.respondent?.device;
  if (name && answer.respondent?.isSession) return t("question.answeredBySession", { name });
  if (name && device) return t("question.answeredBy", { name, device });
  if (name) return t("question.answeredByName", { name });
  if (device) return t("question.answeredOn", { device });
  // The person's app answered for another of their devices, which it names by an install id only.
  if (answer.respondent?.isRemote) return t("question.answeredElsewhere");
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
            <span className="acpmux-question-answered-key">{item.header ?? inlineText(item.prompt)}:</span>{" "}
            {inlineText(itemAnswerText(item, answer))}
          </span>
        ))}
      </span>
      {by && <span className="acpmux-question-answered-by">{by}</span>}
    </div>
  );
}

/// An ask that ended unanswered: one muted line that says how, when the record says (Skip, or the
/// turn stopped before an answer), else "Not answered", and the question.
function CancelledQuestion({ question }: { question: AgentQuestion }) {
  const t = useT();
  return (
    <div
      className="acpmux-question-cancelled"
      data-reason={question.state.kind === "cancelled" ? question.state.reason : undefined}
    >
      {t(cancelledKey(question), cancelledArgs(question))}
    </div>
  );
}
