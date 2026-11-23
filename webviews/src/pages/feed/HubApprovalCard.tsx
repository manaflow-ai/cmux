// One integrations hub approval in Chief's pinned Needs you: which agent asked, which integration
// and action (with its amount and the hub's pinned line naming the target), which rule sent it to
// the person, and Approve and Deny. Answered, it shows what the answer did in their place until the
// next refresh takes it away. Draws only: every word comes shaped from the CLI (hubApprovals.ts).
import { Button } from "../../ui/Button";
import type { Strings } from "../shared/i18n";
import type { HubApprovals, HubCardRow } from "./hubApprovals";

export function HubApprovalCard({ row, hub, strings }: { row: HubCardRow; hub: HubApprovals; strings: Strings }) {
  const { t } = strings;
  const { card, answer, sending } = row;
  const outcome = answer?.call?.outcomeText ?? undefined;
  const refused = answer?.refused;
  const headline = [card.actionText, card.amountText].filter(Boolean).join(" ");
  return (
    <div
      className="feed-hub-card"
      data-approval={card.approvalId}
      data-sending={sending ? "" : undefined}
      data-tone={outcome ? (answer?.call?.outcomeTone ?? "done") : undefined}
    >
      <div className="feed-hub-text">
        <span className="feed-hub-headline">
          <span>{headline}</span>
          <span className="feed-hub-integration">{card.integrationText}</span>
        </span>
        <span className="feed-hub-line" title={card.line}>
          {card.line}
        </span>
        {refused ? (
          <span className="feed-hub-error" role="alert">
            {refused.message || t("hub.answerRefused")}
          </span>
        ) : (
          <span className="feed-hub-meta" title={`${card.agentText} · ${card.ruleText}`}>
            {`${card.agentText} · ${card.ruleText}`}
          </span>
        )}
      </div>
      {outcome ? (
        <output className="feed-hub-outcome">{outcome}</output>
      ) : (
        <div className="feed-hub-answers">
          <Button
            variant="solid"
            disabled={sending}
            aria-busy={sending}
            data-hub-action="approve"
            onClick={() => void hub.answer(card.approvalId, "approve")}
          >
            {t("answer.approve")}
          </Button>
          <Button
            danger
            variant="ghost"
            disabled={sending}
            data-hub-action="deny"
            onClick={() => void hub.answer(card.approvalId, "deny")}
          >
            {t("answer.deny")}
          </Button>
        </div>
      )}
    </div>
  );
}
