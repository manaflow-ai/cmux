import { useContext, useState } from "react";
import type { ComposerAttachment } from "../attachments";
import { useT } from "../i18n";
import type { AcpmuxRow, QueueEdit } from "../model";

/// Under a steer the agent has not read yet: Send now stops the current step so the agent reads the
/// message at once. The turn goes on; only Stop ends it (Leo, 2026-10-20). An agent that cannot
/// stop one step reads it when the step ends, as before. `send` is `_acpmux/queue_edit` `send_now`
/// with the steer's own promptId; it answers false once the steer was read. The control sits in the
/// prompt's action row, before its receipt, age and message buttons (Leo, 2026-10-24).
import { Close } from "./icons";
import { TurnActionsContext } from "./turnActions";

/// Under a steer the agent has not read yet: a quiet clock (it reads a steer when its current
/// step ends), Send now, which stops that step so the agent reads the message at once, and an X
/// that takes the steer back to edit (Leo, 2026-10-21: "THERE'S A CANCEL AND EDIT BY CLICKING THE
/// X BUTTON ON THE SENT MESSAGES TO CLAUDE.. THEY'RE STEERS BUT THEY HAVENT BEEN SENT SOMETIMES
/// WITH THE TOOL CALLS AND WHATNOT WAITING"). The turn goes on; only Stop ends it (Leo,
/// 2026-10-20). An agent that cannot stop one step reads it when the step ends, as before. `send`
/// is `_acpmux/queue_edit` `send_now` with the steer's own promptId; it answers false once the
/// steer was read. The X is the page's `unsteer` (`takeBackSteer`), where the chat offers it.
/// `beside` draws it at the bubble's left edge, on the bubble's first line and out of the layout
/// (UserBubble.tsx), as Claude draws a queued prompt's controls: no line of its own under the
/// bubble (Leo, 2026-10-21).
export function PendingSteer({
  row,
  send,
}: {
  row: AcpmuxRow;
  send: (promptId: string, edit: QueueEdit) => Promise<boolean>;
}) {
  const t = useT();
  const { unsteer } = useContext(TurnActionsContext);
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
      {promptId && unsteer && (
        <button
          type="button"
          className="cv-user__take-back"
          aria-label={t("composer.queueEditMessage")}
          title={t("composer.queueEditMessage")}
          disabled={sending}
          onClick={() => {
            setSending(true);
            void unsteer(row)
              .catch(() => false)
              .finally(() => setSending(false));
          }}
        >
          <Close size={13} />
        </button>
      )}
    </div>
  );
}

/// Takes back steer `row` while the agent has not read it: acpmux drops it (`withdraw`), and its
/// text and attachments go back into the composer to edit. Its attachments are read first (the
/// row goes with acpmux's `steer_withdrawn` record), and one that cannot be read keeps the steer:
/// the composer never gets the text without its images. False, with nothing restored, when the
/// steer stays (read already, or its attachments unreadable).
export async function takeBackSteer(
  row: AcpmuxRow,
  io: {
    withdraw: (promptId: string) => Promise<boolean>;
    attachments: (rowId: string) => Promise<ComposerAttachment[]>;
    restore: (text: string, attachments: ComposerAttachment[]) => void;
  },
): Promise<boolean> {
  const promptId = row.steerPromptId;
  if (!promptId || row.steer !== "waiting") return false;
  const attachments = await io.attachments(row.id).catch(() => undefined);
  // An image acpmux could not give back is left out of what it read: the steer stays then too.
  const images = attachments?.filter((attachment) => attachment.kind === "image").length ?? 0;
  if (!attachments || images < (row.images?.length ?? 0) || !(await io.withdraw(promptId))) return false;
  io.restore(row.resend ?? row.text ?? "", attachments);
  return true;
}
