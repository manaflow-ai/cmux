// The answer controls of one request, by kind (FeedAnswerControls, FeedApproveControls,
// FeedChoiceControls): approve, choice, question, confirm, review, sign-in, passkey, handoff, file,
// input and custom. A closed request shows how it closed instead ("Answered on iPhone"). Every
// answer is an intent to the owner; drafts are the page's until they are sent.
import type { KeyboardEvent } from "react";
import { Button } from "../../ui/Button";
import { cx } from "../../ui/cx";
import { canChange, isPending, plain, type FeedProps } from "./context";
import { FeedIcon } from "./icons";
import { useButtonMenu } from "./menus";
import { Answers, approveScopes, choiceIssues, closedStatus, draftChoice, isOneTap, SCOPE_LABEL } from "./model";
import type { ViewItem } from "./types";

/** How much room the controls get: under a request in a list, or the Inbox detail (every field). */
export type FeedDensity = "inline" | "detail";

type Props = FeedProps & { item: ViewItem; density?: FeedDensity };

export function AnswerControls({ item, store, snap, strings, density = "inline" }: Props) {
  const closed = closedStatus(item, strings);
  if (closed)
    return (
      <span className="feed-closed">
        <FeedIcon name={item.state === "answered" ? "status.success" : "action.remove"} size={12} />
        {closed}
      </span>
    );
  if (item.kind === "notice") return null;
  const disabled = isPending(snap, item) || !canChange(snap, item);
  const props = { item, store, snap, strings, density, disabled };
  switch (item.kind) {
    case "approve":
      return <ApproveControls {...props} />;
    case "choice":
      return <ChoiceControls {...props} />;
    case "question":
      return <QuestionControls {...props} />;
    case "review":
      return <ReviewControls {...props} />;
    case "confirm": {
      const p = item.prompt ?? {};
      return (
        <Buttons
          {...props}
          primary={p.confirm_label || strings.t("answer.confirm")}
          decline={p.cancel_label || undefined}
          destructive={p.destructive === true}
          onDecline={() => store.answer(item.id, Answers.confirm(false))}
          onPrimary={() => store.answer(item.id, Answers.confirm(true))}
        />
      );
    }
    case "sign-in":
      return <Buttons {...props} primary={strings.t("answer.signIn")} onPrimary={() => store.open(item.id)} />;
    case "passkey":
      return <Buttons {...props} primary={strings.t("answer.usePasskey")} onPrimary={() => store.open(item.id)} />;
    case "handoff":
      return (
        <Buttons
          {...props}
          primary={strings.t("answer.takeOver")}
          onPrimary={() => {
            store.answer(item.id, Answers.handoff("taken_over"));
            store.open(item.id);
          }}
        />
      );
    case "file":
      return <Buttons {...props} primary={strings.t("answer.chooseFile")} onPrimary={() => store.open(item.id)} />;
    default:
      // input and custom kinds: their form is the poster's, in its own context.
      return <Buttons {...props} primary={strings.t("answer.open")} onPrimary={() => store.open(item.id)} />;
  }
}

interface ControlProps extends Props {
  density: FeedDensity;
  disabled: boolean;
}

/** Decline (secondary) and the primary action. */
function Buttons({
  item,
  store,
  strings,
  disabled,
  primary,
  decline,
  destructive = false,
  onPrimary,
  onDecline,
}: ControlProps & {
  primary: string;
  decline?: string;
  destructive?: boolean;
  onPrimary: () => void;
  onDecline?: () => void;
}) {
  return (
    <div className="feed-answer-row">
      <Button size="sm" disabled={disabled} onClick={onDecline ?? (() => store.decline(item.id))}>
        {decline ?? strings.t("answer.decline")}
      </Button>
      <Button
        size="sm"
        variant={destructive ? "subtle" : "solid"}
        danger={destructive}
        disabled={disabled}
        onClick={onPrimary}
      >
        {primary}
      </Button>
    </div>
  );
}

/** `approve`: scope (when the poster offers more than one), Deny, Allow. */
function ApproveControls({ item, store, snap, strings, disabled }: ControlProps) {
  const scopes = approveScopes(item);
  const scope = snap.drafts.scopes[item.id] ?? scopes[0]!;
  const [menu, openMenu] = useButtonMenu();
  return (
    <div className="feed-answer-row">
      {scopes.length > 1 ? (
        <button
          type="button"
          className="feed-scope"
          disabled={disabled}
          onClick={(event) =>
            openMenu(
              event,
              scopes.map((option) => ({
                id: option,
                label: strings.t(SCOPE_LABEL[option]),
                run: () => store.setScope(item.id, option),
              })),
            )
          }
        >
          {strings.t(SCOPE_LABEL[scope])}
          <FeedIcon name="control.popup" size={12} />
        </button>
      ) : null}
      <Button size="sm" disabled={disabled} onClick={() => store.approve(item.id, "deny")}>
        {strings.t("answer.deny")}
      </Button>
      <Button size="sm" variant="solid" disabled={disabled} onClick={() => store.approve(item.id, "allow", scope)}>
        {strings.t("answer.allow")}
      </Button>
      {menu}
    </div>
  );
}

/** A plain text field with the theme's faint fill. */
function Field({
  value,
  placeholder,
  disabled,
  onChange,
  onSubmit,
  className,
}: {
  value: string;
  placeholder: string;
  disabled?: boolean;
  onChange: (text: string) => void;
  onSubmit?: () => void;
  className?: string;
}) {
  const keys = (event: KeyboardEvent<HTMLInputElement>) => {
    if (onSubmit && plain(event) && event.key === "Enter" && !event.nativeEvent.isComposing) {
      event.preventDefault();
      onSubmit();
    }
  };
  return (
    <input
      className={cx("feed-field", className)}
      type="text"
      value={value}
      placeholder={placeholder}
      aria-label={placeholder}
      disabled={disabled}
      onChange={(event) => onChange(event.target.value)}
      onKeyDown={keys}
    />
  );
}

/** `choice`: option chips per question, "Other" where allowed, and Send once every question has an
 * answer. A single single-select question answers on the tap. */
function ChoiceControls({ item, store, snap, strings, disabled }: ControlProps) {
  const questions = item.prompt?.questions ?? [];
  const oneTap = isOneTap(questions);
  const issues = choiceIssues(snap.drafts.choices[item.id] ?? {}, questions);
  return (
    <div className="feed-choice">
      {questions.map((question) => {
        const selection = draftChoice(snap.drafts, item.id, question.id);
        return (
          <div key={question.id} className="feed-choice-question">
            <span className="feed-choice-text">{question.question}</span>
            <div className="feed-chips">
              {question.options.map((option) => {
                const selected = selection.selected.includes(option.id);
                return (
                  <button
                    key={option.id}
                    type="button"
                    className="feed-chip"
                    aria-pressed={selected}
                    title={option.description}
                    disabled={disabled}
                    onClick={() => store.toggleChoice(item.id, question, option.id, oneTap)}
                  >
                    {option.label}
                  </button>
                );
              })}
            </div>
            {question.allow_other ? (
              <Field
                className="feed-other"
                value={selection.other ?? ""}
                placeholder={strings.t("answer.other")}
                disabled={disabled}
                onChange={(text) => store.setOther(item.id, question, text)}
              />
            ) : null}
          </div>
        );
      })}
      {oneTap ? null : (
        <div className="feed-answer-row">
          <Button size="sm" disabled={disabled} onClick={() => store.decline(item.id)}>
            {strings.t("answer.decline")}
          </Button>
          <Button
            size="sm"
            variant="solid"
            disabled={disabled || issues.length > 0}
            title={issues.length ? strings.t("answer.pickOne") : undefined}
            onClick={() => store.submitChoice(item.id)}
          >
            {strings.t("answer.send")}
          </Button>
        </div>
      )}
    </div>
  );
}

/** `question`: suggestion chips that fill the reply, the reply, Send. */
function QuestionControls({ item, store, snap, strings, disabled }: ControlProps) {
  const reply = snap.drafts.replies[item.id] ?? "";
  const suggestions = item.prompt?.suggestions ?? [];
  return (
    <div className="feed-question">
      {suggestions.length ? (
        <div className="feed-chips">
          {suggestions.map((suggestion) => (
            <button
              key={suggestion}
              type="button"
              className="feed-chip"
              aria-pressed={reply === suggestion}
              disabled={disabled}
              onClick={() => store.setReply(item.id, suggestion)}
            >
              {suggestion}
            </button>
          ))}
        </div>
      ) : null}
      <div className="feed-answer-row feed-reply-row">
        <Field
          value={reply}
          placeholder={strings.t("answer.reply")}
          disabled={disabled}
          onChange={(text) => store.setReply(item.id, text)}
          onSubmit={() => store.sendReply(item.id)}
        />
        <Button size="sm" variant="solid" disabled={disabled || !reply.trim()} onClick={() => store.sendReply(item.id)}>
          {strings.t("answer.send")}
        </Button>
      </div>
    </div>
  );
}

/** `review`: an optional comment (detail), Request Changes, Approve. */
function ReviewControls({ item, store, snap, strings, density, disabled }: ControlProps) {
  return (
    <div className="feed-question">
      {density === "detail" ? (
        <Field
          value={snap.drafts.replies[item.id] ?? ""}
          placeholder={strings.t("answer.reply")}
          disabled={disabled}
          onChange={(text) => store.setReply(item.id, text)}
        />
      ) : null}
      <div className="feed-answer-row">
        <Button size="sm" disabled={disabled} onClick={() => store.review(item.id, "request_changes")}>
          {strings.t("answer.requestChanges")}
        </Button>
        <Button size="sm" variant="solid" disabled={disabled} onClick={() => store.review(item.id, "approve")}>
          {strings.t("answer.approve")}
        </Button>
      </div>
    </div>
  );
}
