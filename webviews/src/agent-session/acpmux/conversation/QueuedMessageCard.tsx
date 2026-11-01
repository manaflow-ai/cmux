// Another agent's message waiting in the queue (a `QUEUED_MESSAGE` row, queuedMessages.ts): its
// received line, as it reads once delivered, in the one group of messages that wait
// (PendingMessagesCard.tsx), with no "Read after this turn" (Leo, 2026-10-29: "why the fuck do you
// guys keep doing this fucking bullshit with the red after this turn?"). Its actions are a message's,
// never the person's queue row's (Leo, 2026-10-29: "WHY AM I SEEING TURN OFF QUEUING ON AGENT
// MESSAGES????"): ⋯ with Send now (into the running turn, `send_now`,
// once) and Dismiss (the agent never gets it), in one group as on a delivered message's line. No
// Edit message, Move up or down, or queueing switch: those are the person's own prompts'
// (ComposerQueue.tsx). The sender's chat opens from its name (IncomingMessageCard.tsx).
import { useContext, useState } from "react";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import type { AcpmuxRow, QueuedPromptImage } from "../model";
import { Menu, MenuButton, MenuItem, MenuPopup } from "../../../ui/Menu";
import { IncomingMessageLine } from "./IncomingMessageCard";
import type { IncomingMessage } from "./incomingMessage";
import { MessageFooterRow } from "./MessageActions";
import { TurnActionsContext } from "./turnActions";

/// What the ⋯ menu does (App.tsx, through TurnActions `queuedMessages`); each is false once the
/// message started. `edit`, `sideChat`, `position` and `move` serve the person's own queue rows.
export type QueuedMessageActionsValue = {
  steer: (promptId: string) => Promise<boolean>;
  edit: (promptId: string, text: string, images: readonly QueuedPromptImage[]) => Promise<boolean>;
  remove: (promptId: string) => Promise<boolean>;
  sideChat?: (promptId: string, text: string) => Promise<boolean>;
  /// Where it waits in the whole queue now (the person's prompts too), for Move up and Move down.
  position?: (promptId: string) => { index: number; count: number } | undefined;
  /// Moves it to `index` in the whole queue (`_acpmux/queue_edit` move).
  move?: (promptId: string, index: number) => Promise<boolean>;
};

/// A waiting message's ⋯: Send now when it can go into the running turn, and Dismiss when it can
/// be taken back; nothing when neither. Never the person's queue actions. Copy is the opened card's
/// corner Copy (CardCopy), as on every other message from another session.
export function WaitingMessageMenu({ sendNow, dismiss }: { sendNow?: () => void; dismiss?: () => void }) {
  const t = useT();
  if (!sendNow && !dismiss) return null;
  return (
    <Menu>
      <MenuButton
        className="cv-iconbtn cv-iconbtn--compact"
        data-menu="waiting-message"
        label={t("composer.queueActions")}
        title={t("composer.queueActions")}
        aria-haspopup="menu"
      >
        <Icon name="action.more" size={14} />
      </MenuButton>
      <MenuPopup
        side="bottom"
        align="end"
        className="acpmux-quick-menu acpmux-queued-more"
        label={t("composer.queueActions")}
      >
        {sendNow && (
          <MenuItem className="acpmux-quick-item" onSelect={sendNow}>
            {t("steer.sendNow")}
          </MenuItem>
        )}
        {dismiss && (
          <MenuItem className="acpmux-quick-item" onSelect={dismiss}>
            {t("message.dismiss")}
          </MenuItem>
        )}
      </MenuPopup>
    </Menu>
  );
}

export function QueuedMessageCard({
  row,
  onOpen,
  onReply,
  githubRepository,
}: {
  row: AcpmuxRow;
  /// Opens the sender's chat by its acpmux id.
  onOpen(sessionId: string): void;
  onReply?(message: IncomingMessage, text: string): Promise<void>;
  githubRepository?: string;
}) {
  const t = useT();
  const act = useContext(TurnActionsContext).queuedMessages?.();
  // Send now goes once: hidden from its reply until acpmux's next word on the message (a new row).
  const [sentAt, setSentAt] = useState<number>();
  const queued = row.queuedMessage;
  if (!queued || row.incoming?.kind !== "message") return null;
  const { promptId } = queued;
  const message = row.incoming.message;
  const fail = () => undefined;
  // The same group as a delivered message's (MessageActions.tsx ReceivedActions): its ⋯. No hover
  // Copy: the opened card's corner Copy copies it (Leo, 2026-10-30).
  const actions = (
    <span className="cv-received-actions">
      <MessageFooterRow>
        <WaitingMessageMenu
          sendNow={
            act && !queued.next && sentAt !== row.version
              ? () => void act.steer(promptId).then((ok) => ok && setSentAt(row.version), fail)
              : undefined
          }
          dismiss={act ? () => void act.remove(promptId).catch(fail) : undefined}
        />
      </MessageFooterRow>
    </span>
  );
  return (
    <div className="cv-incoming" data-queued-message={promptId}>
      {queued.lead && queued.heldByStop && <div className="cv-received__queued-head">{t("message.heldByStop")}</div>}
      <IncomingMessageLine
        id={row.id}
        message={message}
        images={row.images}
        onOpen={onOpen}
        onReply={onReply}
        actions={actions}
        githubRepository={githubRepository}
      />
    </div>
  );
}

/// A message another agent steered into the running turn that the agent has not read yet
/// (`steer === "waiting"`), in the group of messages that wait: its ⋯ in the message's own action
/// group (MessageActions.tsx ReceivedActions `more`), with Send now (`send_now` with the steer's
/// promptId, which stops the current step). No spinner row, no dot, and no "Read after this step"
/// tag: the group says the messages wait (Leo, 2026-10-25, 2026-10-29).
export function SteerWaitingActions({ promptId, send }: { promptId?: string; send: (promptId: string) => void }) {
  return <WaitingMessageMenu sendNow={promptId ? () => send(promptId) : undefined} />;
}
