// A Chief's permission card in the transcript (Swift `HomeApprovalRowProvider.drawRow`): a received
// bubble with the request's prompt, the tool's input while it waits and where it stands, over Deny
// and Allow. The buttons take clicks while the request waits and no decision is in flight; they go
// once the card ended. The state lives in the transcript's `ApprovalDecisions`, so a card that
// scrolls out and back keeps its note.
import { useSyncExternalStore } from "react";
import { Button } from "../../../../ui/Button";
import type { HomeMessage, HomeQuestion } from "../../../home-channels/types";
import type { Strings } from "../../../shared/i18n";
import {
  APPROVAL_NOTE_KEYS,
  approvalButtons,
  approvalInput,
  approvalKey,
  approvalStatus,
  visible,
  type ApprovalDecisions,
} from "./approval";
import "../parts/parts.css";

export interface ApprovalCardProps {
  message: HomeMessage;
  partIndex: number;
  question: HomeQuestion;
  strings: Strings;
  /** The transcript's decisions; absent (no app): the card shows no buttons. */
  decisions?: ApprovalDecisions;
}

const NO_STATE = () => () => {};
const ZERO = () => 0;

export function ApprovalCard({ message, partIndex, question, strings, decisions }: ApprovalCardProps) {
  const { t } = strings;
  useSyncExternalStore(decisions?.states.subscribe ?? NO_STATE, decisions?.states.getSnapshot ?? ZERO);
  const local = decisions?.states.get(approvalKey(message, partIndex));
  const title = question.items[0]?.prompt ?? "";
  const input = approvalInput(question);
  const status = approvalStatus(question, local);
  const buttons = decisions !== undefined && approvalButtons(question, local);
  const takesClicks = buttons && !local?.busy;
  return (
    <div className="mt-bubble in tail hm-approval">
      <span className="hm-approval__text">{visible(title)}</span>
      {input && <pre className="hm-approval__input">{visible(input)}</pre>}
      {status && <output className="hm-approval__note">{t(APPROVAL_NOTE_KEYS[status])}</output>}
      {buttons && (
        <div className="hm-approval__buttons">
          <Button
            variant="subtle"
            size="md"
            disabled={!takesClicks}
            onClick={() => void decisions?.decide(message, partIndex, false)}
          >
            {t("home.approval.deny")}
          </Button>
          <Button
            variant="solid"
            size="md"
            disabled={!takesClicks}
            onClick={() => void decisions?.decide(message, partIndex, true)}
          >
            {t("home.approval.allow")}
          </Button>
        </div>
      )}
    </div>
  );
}
