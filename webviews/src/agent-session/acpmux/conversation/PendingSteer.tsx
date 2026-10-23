import { useState } from "react";
import { useT } from "../i18n";
import type { AcpmuxRow, QueueEdit } from "../model";
import { Clock } from "./icons";

/// Under a steer the agent has not read yet: a quiet clock (it reads a steer when its current
/// step ends) and Send now, which stops that step so the agent reads the message at once. The
/// turn goes on; only Stop ends it (Leo, 2026-10-20). An agent that cannot stop one step reads it
/// when the step ends, as before. `send` is `_acpmux/queue_edit` `send_now` with the steer's own
/// promptId; it answers false once the steer was read. `beside` draws it at the bubble's left edge,
/// on the bubble's first line and out of the layout (UserBubble.tsx), as Claude draws a queued
/// prompt's controls: no line of its own under the bubble (Leo, 2026-10-21).
export function PendingSteer({
  row,
  send,
  beside = false,
}: {
  row: AcpmuxRow;
  send: (promptId: string, edit: QueueEdit) => Promise<boolean>;
  beside?: boolean;
}) {
  const t = useT();
  const [sending, setSending] = useState(false);
  if (row.steer !== "waiting") return null;
  const promptId = row.steerPromptId;
  return (
    <div className={beside ? "cv-user__pending cv-user__pending--beside" : "cv-user__pending"}>
      <span className="cv-user__pending-clock" title={t("steer.pending")}>
        <Clock size={13} />
      </span>
      {promptId && (
        <button
          type="button"
          className="cv-user__send-now"
          // tooltip-allow: says Send now stops only the current step, not the turn; shown nowhere else
          title={t("steer.sendNowHelp")}
          disabled={sending}
          onClick={() => {
            setSending(true);
            void send(promptId, { op: "send_now" })
              .catch(() => false)
              .finally(() => setSending(false));
          }}
        >
          {t("steer.sendNow")}
        </button>
      )}
    </div>
  );
}
