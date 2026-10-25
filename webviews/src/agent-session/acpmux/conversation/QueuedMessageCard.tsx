// Another agent's message the agent has not read yet (queuedMessages.ts): its received card says so
// with one quiet note at the line's end, never a spinner or a pulsing dot (Leo, 2026-10-25). A
// queued message is read after the running turn; a steered one when the agent's current step ends.
// The card's ⋯ menu acts on it: Steer (`_acpmux/queue_edit` send_now), Edit message (back into the
// composer), queueing off or on (queueing.ts), and Delete. A menu opens on the click (ui/Menu).
import { useContext, useState } from "react";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import type { AcpmuxRow } from "../model";
import { Menu, MenuButton, MenuItem, MenuPopup } from "../../../ui/Menu";
import { setQueueing, useQueueing } from "../queueing";
import { IncomingMessageLine } from "./IncomingMessageCard";
import type { IncomingMessage } from "./incomingMessage";
import { TurnActionsContext } from "./turnActions";

/// The note: when the agent reads the message, after the running turn or after its current step.
export function QueuedMessageNote({ after }: { after: "turn" | "step" }) {
  const t = useT();
  return (
    <span className="cv-received__queued" data-after={after}>
      {t(after === "turn" ? "message.readAfterTurn" : "message.readAfterStep")}
    </span>
  );
}

export type QueuedMessageActions = {
  /// Sends the message now: a queued one steers into the running turn, a steer stops the step.
  steer?: () => void;
  /// Takes a queued message out of the queue into the composer, to edit and send as the person's.
  edit?: () => void;
  /// Withdraws it from the queue.
  remove?: () => void;
  /// Whether the menu offers queueing off or on, as a queue row's ⋯ did.
  queueing?: boolean;
  /// The steer's label: "Steer" for a queued message, "Send now" for a steer.
  steerLabel?: "composer.queueSteer" | "steer.sendNow";
};

/// The card's ⋯ menu, at the line's end with its hover row; nothing when it offers no action.
export function QueuedMessageMenu({
  steer,
  edit,
  remove,
  queueing: offersQueueing,
  steerLabel = "composer.queueSteer",
}: QueuedMessageActions) {
  const t = useT();
  const queueing = useQueueing();
  if (!steer && !edit && !remove && !offersQueueing) return null;
  return (
    <span className="cv-received-actions cv-received__queued-actions">
      <Menu>
        <MenuButton
          className="cv-iconbtn cv-iconbtn--compact"
          data-menu="queued-message"
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
          {steer && (
            <MenuItem className="acpmux-quick-item" onSelect={steer}>
              {t(steerLabel)}
            </MenuItem>
          )}
          {edit && (
            <MenuItem className="acpmux-quick-item" onSelect={edit}>
              {t("composer.queueEditMessage")}
            </MenuItem>
          )}
          {offersQueueing && (
            <MenuItem className="acpmux-quick-item" onSelect={() => setQueueing(!queueing)}>
              {t(queueing ? "composer.queueingOff" : "composer.queueingOn")}
            </MenuItem>
          )}
          {remove && (
            <MenuItem className="acpmux-quick-item" onSelect={remove}>
              {t("composer.queueDelete")}
            </MenuItem>
          )}
        </MenuPopup>
      </Menu>
    </span>
  );
}

/// Another agent's message waiting in the queue (a `QUEUED_MESSAGE` row, queuedMessages.ts): its
/// received card, as it reads once delivered (collapsed in Minimal Mode as any is), with "Read after
/// this turn" and its ⋯ menu: Steer, Edit message (a message without images: the composer's edit
/// would drop them), queueing off or on, and Delete, the actions its queue row had. Steer goes once:
/// acpmux marks it next (an agent that cannot steer runs it after the turn), or starts it.
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
  const { queuedMessage: act } = useContext(TurnActionsContext);
  const [steered, setSteered] = useState(false);
  const queued = row.queuedMessage;
  if (!queued || row.incoming?.kind !== "message") return null;
  const { promptId } = queued;
  const message = row.incoming.message;
  // The prompt as it waits, which Edit message puts in the composer.
  const text = message.raw;
  const fail = () => undefined;
  return (
    <div className="cv-incoming" data-queued-message={promptId}>
      <IncomingMessageLine
        id={row.id}
        message={message}
        images={row.images}
        onOpen={onOpen}
        onReply={onReply}
        actions={
          <>
            <QueuedMessageNote after="turn" />
            <QueuedMessageMenu
              {...(act && !queued.next && !steered
                ? { steer: () => void act.steer(promptId).then((ok) => ok && setSteered(true), fail) }
                : {})}
              {...(act && !row.images?.length ? { edit: () => void act.edit(promptId, text).catch(fail) } : {})}
              {...(act ? { remove: () => void act.remove(promptId).catch(fail) } : {})}
              queueing
            />
          </>
        }
        githubRepository={githubRepository}
      />
    </div>
  );
}
