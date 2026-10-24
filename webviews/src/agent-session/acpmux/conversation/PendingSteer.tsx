import { useState } from "react";
import { useT } from "../i18n";
import type { AcpmuxRow, QueueEdit } from "../model";

/// Under a steer the agent has not read yet: Send now stops the current step so the agent reads the
/// message at once. The turn goes on; only Stop ends it (Leo, 2026-10-20). An agent that cannot
/// stop one step reads it when the step ends, as before. `send` is `_acpmux/queue_edit` `send_now`
/// with the steer's own promptId; it answers false once the steer was read. The control sits in the
/// prompt's action row, before its receipt, age and message buttons (Leo, 2026-10-24).
export function PendingSteer({
  row,
  send,
}: {
  row: AcpmuxRow;
  send: (promptId: string, edit: QueueEdit) => Promise<boolean>;
}) {
  const t = useT();
  const [sending, setSending] = useState(false);
  if (row.steer !== "waiting") return null;
  const promptId = row.steerPromptId;
  return (
    <div className="cv-user__pending">
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
