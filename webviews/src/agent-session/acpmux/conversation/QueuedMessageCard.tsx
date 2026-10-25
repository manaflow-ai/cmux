// Another agent's message the agent has not read yet (queuedMessages.ts): its received card says so
// with one quiet note at the line's end, never a spinner or a pulsing dot (Leo, 2026-10-25). A
// queued message is read after the running turn; a steered one when the agent's current step ends.
// The card's ⋯ menu acts on it: Steer (`_acpmux/queue_edit` send_now), Edit message (back into the
// composer), queueing off or on (queueing.ts), and Delete. A menu opens on the click (ui/Menu).
import { useContext, useState } from "react";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import type { AcpmuxRow, QueuedPromptImage } from "../model";
import { Menu, MenuButton, MenuItem, MenuPopup } from "../../../ui/Menu";
import { setQueueing, useQueueing } from "../queueing";
import { IncomingMessageLine } from "./IncomingMessageCard";
import type { IncomingMessage } from "./incomingMessage";
import { TurnActionsContext } from "./turnActions";

/// What a waiting message's ⋯ menu does (App.tsx, through TurnActions `queuedMessages`): Steer it now (`send_now`), take it
/// into the composer with its images to edit, ask it in a side chat (where the chat opens one; a
/// message with images stays, as a side chat asks the text alone), or delete it. Each is false when
/// it already started.
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
  /// Asks it in a new side chat and withdraws it from the queue (the queue row's Open in side chat).
  sideChat?: () => void;
  /// Where it waits now and how to move it there, read as the menu opens (the queue row's Move up
  /// and Move down; the first can't move up, the last can't move down).
  place?: { position: () => { index: number; count: number } | undefined; move: (index: number) => void };
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
  sideChat,
  place,
  queueing: offersQueueing,
  steerLabel = "composer.queueSteer",
}: QueuedMessageActions) {
  const t = useT();
  const queueing = useQueueing();
  // Opening draws the menu again, so its moves read where the message waits now.
  const [, setOpened] = useState(0);
  if (!steer && !edit && !remove && !sideChat && !place && !offersQueueing) return null;
  const at = place?.position();
  return (
    <span className="cv-received-actions cv-received__queued-actions">
      <Menu onOpenChange={(open) => open && setOpened((count) => count + 1)}>
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
          {sideChat && (
            <MenuItem className="acpmux-quick-item" onSelect={sideChat}>
              {t("composer.queueSideChat")}
            </MenuItem>
          )}
          {place && at && (
            <>
              <MenuItem
                className="acpmux-quick-item"
                disabled={at.index === 0}
                onSelect={() => place.move(at.index - 1)}
              >
                {t("composer.queueMoveUp")}
              </MenuItem>
              <MenuItem
                className="acpmux-quick-item"
                disabled={at.index >= at.count - 1}
                onSelect={() => place.move(at.index + 1)}
              >
                {t("composer.queueMoveDown")}
              </MenuItem>
            </>
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
/// this turn" and its ⋯ menu: Steer, Edit message (into the composer, images too), Open in side chat
/// (a message without images), queueing off or on, and Delete, the actions its queue row had. Steer
/// goes once: acpmux marks it next (an agent that cannot steer runs it after the turn), or starts it.
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
            <QueuedMessageMenu
              {...(act && !queued.next && !steered
                ? { steer: () => void act.steer(promptId).then((ok) => ok && setSteered(true), fail) }
                : {})}
              {...(act ? { edit: () => void act.edit(promptId, text, row.images ?? []).catch(fail) } : {})}
              {...(act?.sideChat && !row.images?.length
                ? { sideChat: () => void act.sideChat!(promptId, text).catch(fail) }
                : {})}
              {...(act?.position && act.move
                ? {
                    place: {
                      position: () => act.position!(promptId),
                      move: (index: number) => void act.move!(promptId, index).catch(fail),
                    },
                  }
                : {})}
              {...(act ? { remove: () => void act.remove(promptId).catch(fail) } : {})}
              queueing
            />
            {/* Last: a row's focus Copy (App.tsx) sits over the line's end, never over the menu. */}
            <QueuedMessageNote after="turn" />
          </>
        }
        githubRepository={githubRepository}
      />
    </div>
  );
}
