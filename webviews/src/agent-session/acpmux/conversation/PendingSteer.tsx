import { useContext, useState, type ReactNode } from "react";
import type { ComposerAttachment } from "../attachments";
import { useT } from "../i18n";
import type { AcpmuxRow, QueueEdit } from "../model";
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
/// Queue controls replace normal hover actions until Send now is accepted or the agent reads it.
/// A refusal keeps the controls available. Accepted delivery removes them in the same render.
export function PendingSteer({
  row,
  send,
  children,
}: {
  row: AcpmuxRow;
  send: (promptId: string, edit: QueueEdit) => Promise<boolean>;
  children?: ReactNode;
}) {
  const t = useT();
  const { unsteer } = useContext(TurnActionsContext);
  const [sending, setSending] = useState(false);
  const waiting = row.steer === "waiting";
  const [sentNow, setSentNow] = useState(false);
  const promptId = row.steerPromptId;
  // The transcript virtualizes rows: a remount must not offer an accepted send again.
  if (!waiting || sentNow || (promptId && sentNowIds.has(promptId))) return children ?? null;
  if (!promptId) return null;
  const busy = sending;
  return (
    <div className="cv-user__pending">
      {promptId && (
        <button
          type="button"
          className="cv-user__send-now"
          // tooltip-allow: says Send now stops only the current step, not the turn; shown nowhere else
          title={t("steer.sendNowHelp")}
          disabled={busy}
          onClick={() => {
            setSending(true);
            void send(promptId, { op: "send_now" })
              .catch(() => false)
              .then((sent) => {
                if (!sent) return;
                sentNowIds.add(promptId);
                setSentNow(true);
              })
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
          disabled={busy}
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

/// The steers whose Send now worked, by promptId, so a row drawn again while acpmux still says the
/// steer waits (scrolled away and back) shows no controls. One id per click, for the page's life.
const sentNowIds = new Set<string>();

/// Whether the chat's X takes a waiting steer back (`_acpmux/steer_withdraw`): only acpmux's Claude
/// Code adapter does. acpmux's `backgroundsWork` marks a chat that runs it, whatever its family is
/// named (Leo's claude-sr2); `steering` alone does not, as other ACP agents steer too.
export function takesSteersBack(summary: { backgroundsWork?: boolean } | undefined, connected: boolean): boolean {
  return connected && summary?.backgroundsWork === true;
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
    draft?: (rowId: string, text: string) => Promise<{ input: string; attachments: ComposerAttachment[] }>;
    restore: (text: string, attachments: ComposerAttachment[]) => void;
  },
): Promise<boolean> {
  const promptId = row.steerPromptId;
  if (!promptId || row.steer !== "waiting") return false;
  const text = row.resend ?? row.text ?? "";
  const draft = await (
    io.draft ? io.draft(row.id, text) : io.attachments(row.id).then((attachments) => ({ input: text, attachments }))
  ).catch(() => undefined);
  const attachments = draft?.attachments;
  // An image acpmux could not give back is left out of what it read: the steer stays then too.
  const images = attachments?.filter((attachment) => attachment.kind === "image").length ?? 0;
  if (!draft || images < (row.images?.length ?? 0) || !(await io.withdraw(promptId))) return false;
  io.restore(draft.input, draft.attachments);
  return true;
}
