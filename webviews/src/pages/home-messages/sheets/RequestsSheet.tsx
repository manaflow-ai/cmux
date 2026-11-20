// Message Requests: invites from people the user has not talked to, each with Accept, Decline and
// Block. They made no sound and badge nothing; the sender learns nothing from a decline or a
// block. Accept closes the sheet on the conversation; the others take the request off the sheet.
// One answer runs at a time; a refusal keeps the request and says it failed. Done (↩) closes.
import { useState } from "react";
import type { Strings } from "../../shared/i18n";
import { DialogButton } from "../../../ui/DialogButton";
import type { RequestsActions } from "./actions";
import type { MessageRequest, RequestAnswer } from "./model";
import { SheetFrame, useSheetRun } from "./SheetFrame";

export interface RequestsSheetProps {
  strings: Strings;
  /** The requests as the model last listed them. */
  requests: readonly MessageRequest[];
  actions: RequestsActions;
  /** The sheet closed, on the accepted conversation or on nothing. */
  onFinish(conversation: string | null): void;
}

export function RequestsSheet({ strings, requests, actions, onFinish }: RequestsSheetProps) {
  const { t, format } = strings;
  const sheet = useSheetRun(strings, onFinish);
  // Answered here: gone from the sheet until the model lists them again.
  const [answered, setAnswered] = useState<ReadonlySet<string>>(new Set());
  const shown = requests.filter((request) => !answered.has(request.conversation));
  const choose = (conversation: string, answer: RequestAnswer) => {
    if (sheet.running) return;
    sheet.setRunning(true);
    sheet.setStatus(null);
    void actions.answer(conversation, answer).then((done) => {
      sheet.setRunning(false);
      if (!done) return sheet.setStatus(t("home.outcome.failed"));
      if (answer === "accept") sheet.finish(conversation);
      else setAnswered((before) => new Set([...before, conversation]));
    });
  };
  const button = (request: MessageRequest, answer: RequestAnswer, primary: boolean) => (
    <DialogButton
      dialogKey={null}
      className={primary ? "hc-text-button primary" : "hc-text-button"}
      disabled={sheet.running}
      data-testid={`cmux.home.requests.${answer}.${request.conversation}`}
      onClick={() => choose(request.conversation, answer)}
    >
      {t(`home.requests.${answer}`)}
    </DialogButton>
  );
  return (
    <SheetFrame
      strings={strings}
      id="cmux.home.requests"
      title={t("home.requests.title")}
      primary={t("home.requests.done")}
      canSubmit
      running={false}
      status={sheet.status}
      onSubmit={() => sheet.finish(null)}
      onCancel={() => sheet.finish(null)}
    >
      <p className="hm-sheet-caption">{t("home.requests.body")}</p>
      <div className="hm-requests" data-testid="cmux.home.requests.list">
        {shown.length === 0 && <p className="hm-sheet-empty">{t("home.requests.none")}</p>}
        {shown.map((request) => {
          const lines = [
            request.isGroup
              ? request.title
                ? format("home.requests.group", request.title)
                : t("home.requests.groupUntitled")
              : "",
            request.preview,
          ].filter(Boolean);
          return (
            <section
              key={request.conversation}
              className="hm-request"
              aria-label={[request.inviter, request.isGroup ? (request.title ?? "") : "", request.preview]
                .filter(Boolean)
                .join(", ")}
            >
              <header className="hm-request-head">
                <span className="hm-request-name">{request.inviter}</span>
                {request.trusted && <span className="hm-sheet-tag">{t("home.requests.trusted")}</span>}
              </header>
              {lines.map((line, index) => (
                <p key={index} className="hm-request-line">
                  {line}
                </p>
              ))}
              <div className="hm-request-buttons">
                {button(request, "accept", true)}
                {button(request, "decline", false)}
                {button(request, "block", false)}
              </div>
            </section>
          );
        })}
      </div>
    </SheetFrame>
  );
}
