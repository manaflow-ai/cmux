// One integrations hub approval in Chief's pinned Needs you, drawn as the section's other request rows
// (NeedsYouView's NeedsYouRow, AnswerControls' approve kind): a leading glyph, the hub's pinned line
// naming the action, amount and target, one meta line (who asked, the integration, the rule that sent
// it to the person), then Deny and Approve. Answered, the answers give way to what the answer did, as
// a closed request's do, until the next refresh takes the row away. Draws only: every word comes
// shaped from the CLI (hubApprovals.ts).
import { Button } from "../../ui/Button";
import { cx } from "../../ui/cx";
import type { Strings } from "../shared/i18n";
import type { HubApprovals, HubCardRow } from "./hubApprovals";
import { FeedIcon } from "./icons";

export function HubApprovalCard({ row, hub, strings }: { row: HubCardRow; hub: HubApprovals; strings: Strings }) {
  const { t } = strings;
  const { card, answer, sending } = row;
  const outcome = answer?.call?.outcomeText ?? undefined;
  const tone = answer?.call?.outcomeTone ?? "done";
  const refused = answer?.refused ? answer.refused.message || t("hub.answerRefused") : undefined;
  const meta = refused ?? [card.agentText, card.integrationText, card.ruleText].filter(Boolean).join(" · ");
  return (
    <div
      className={cx("feed-needs-row", "feed-hub-row", sending && "pending")}
      data-approval={card.approvalId}
      data-tone={outcome ? tone : undefined}
    >
      <div className="feed-needs-opener">
        <span className="feed-glyph" data-tone="attention">
          <FeedIcon name="security.lock" size={16} />
        </span>
        <span className="feed-needs-text">
          <span className="feed-needs-headline" title={card.line}>
            {card.line}
          </span>
          <span className="feed-needs-meta" title={meta} role={refused ? "status" : undefined}>
            {meta}
          </span>
        </span>
      </div>
      <div className="feed-needs-answers">
        {outcome ? (
          <span className="feed-closed">
            <FeedIcon name={tone === "done" ? "status.success" : "action.remove"} size={12} />
            {outcome}
          </span>
        ) : (
          <div className="feed-answer-row">
            <Button
              size="sm"
              disabled={sending}
              data-hub-action="deny"
              onClick={() => void hub.answer(card.approvalId, "deny")}
            >
              {t("answer.deny")}
            </Button>
            <Button
              size="sm"
              variant="solid"
              disabled={sending}
              aria-busy={sending}
              data-hub-action="approve"
              onClick={() => void hub.answer(card.approvalId, "approve")}
            >
              {t("answer.approve")}
            </Button>
          </div>
        )}
      </div>
    </div>
  );
}
