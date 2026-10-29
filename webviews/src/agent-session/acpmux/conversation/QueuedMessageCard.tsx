// Another agent's message waiting in the queue (a `QUEUED_MESSAGE` row, queuedMessages.ts): its
// received line, as it reads once delivered, in the one group of messages that wait
// (PendingMessagesCard.tsx), with no "Read after this turn" (Leo, 2026-10-29: "why the fuck do you
// guys keep doing this fucking bullshit with the red after this turn?"). Its ⋯ menu is a message's,
// never the person's queue row's (Leo, 2026-10-29: "WHY AM I SEEING TURN OFF QUEUING ON AGENT
// MESSAGES????"): Send now (into the running turn, `send_now`, once), Copy, and Dismiss (the agent
// never gets it). No Edit message, Move up or down, or queueing switch: those are the person's own
// prompts' (ComposerQueue.tsx). The sender's chat opens from its name (IncomingMessageCard.tsx).
import { useContext, useState } from "react";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import type { AcpmuxRow, QueuedPromptImage } from "../model";
import { Menu, MenuButton, MenuItem, MenuPopup } from "../../../ui/Menu";
import { IncomingMessageLine } from "./IncomingMessageCard";
import type { IncomingMessage } from "./incomingMessage";
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

const copy = (text: string) => void navigator.clipboard?.writeText(text).catch(() => undefined);

/// A waiting message's ⋯ menu: Send now when it can go into the running turn, Copy, and Dismiss
/// when it can be taken back. Never the person's queue actions.
export function WaitingMessageMenu({
  text,
  sendNow,
  dismiss,
}: {
  text: string;
  sendNow?: () => void;
  dismiss?: () => void;
}) {
  const t = useT();
  return (
    <span className="cv-received-actions cv-received__queued-actions">
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
          <MenuItem className="acpmux-quick-item" onSelect={() => copy(text)}>
            {t("turn.copy")}
          </MenuItem>
          {dismiss && (
            <MenuItem className="acpmux-quick-item" onSelect={dismiss}>
              {t("message.dismiss")}
            </MenuItem>
          )}
        </MenuPopup>
      </Menu>
    </span>
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
  const act = useContext(TurnActionsContext).queuedMessages?.();
  // Send now goes once: hidden from its reply until acpmux's next word on the message (a new row).
  const [sentAt, setSentAt] = useState<number>();
  const queued = row.queuedMessage;
  if (!queued || row.incoming?.kind !== "message") return null;
  const { promptId } = queued;
  const message = row.incoming.message;
  const fail = () => undefined;
  const menu = (
    <WaitingMessageMenu
      text={message.text}
      sendNow={
        act && !queued.next && sentAt !== row.version
          ? () => void act.steer(promptId).then((ok) => ok && setSentAt(row.version), fail)
          : undefined
      }
      dismiss={act ? () => void act.remove(promptId).catch(fail) : undefined}
    />
  );
  return (
    <div className="cv-incoming" data-queued-message={promptId}>
      <IncomingMessageLine
        id={row.id}
        message={message}
        images={row.images}
        onOpen={onOpen}
        onReply={onReply}
        actions={menu}
        githubRepository={githubRepository}
      />
    </div>
  );
}

/// A message another agent steered into the running turn that the agent has not read yet
/// (`steer === "waiting"`), in the group of messages that wait: its ⋯ menu, Send now (`send_now`
/// with the steer's promptId, which stops the current step) and Copy. No spinner row, no dot, and
/// no "Read after this step" tag: the group says the messages wait (Leo, 2026-10-25, 2026-10-29).
export function SteerWaitingActions({
  promptId,
  text,
  send,
}: {
  promptId?: string;
  text: string;
  send: (promptId: string) => void;
}) {
  return <WaitingMessageMenu text={text} sendNow={promptId ? () => send(promptId) : undefined} />;
}
