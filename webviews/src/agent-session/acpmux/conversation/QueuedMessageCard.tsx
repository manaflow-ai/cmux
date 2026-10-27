// Another agent's message waiting in the queue (a `QUEUED_MESSAGE` row, queuedMessages.ts): its
// received card, as it reads once delivered (collapsed in Minimal Mode as any is), with one quiet
// "Read after this turn" at the line's end, never a spinner or a pulsing dot (Leo, 2026-10-25). Its
// ⋯ menu keeps the queue row's actions: Steer (`send_now`, once), Edit message (into the composer,
// images too), Open in side chat (a message without images), Move up/down, queueing, Delete.
import { useContext, useState } from "react";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import type { AcpmuxRow, QueuedPromptImage } from "../model";
import { Menu, MenuButton, MenuItem, MenuPopup } from "../../../ui/Menu";
import { setQueueing, useQueueing } from "../queueing";
import { IncomingMessageLine } from "./IncomingMessageCard";
import type { IncomingMessage } from "./incomingMessage";
import { TurnActionsContext } from "./turnActions";

/// What the ⋯ menu does (App.tsx, through TurnActions `queuedMessages`); each is false once the
/// message started.
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
  const queueing = useQueueing();
  const act = useContext(TurnActionsContext).queuedMessages?.();
  // Steer goes once: hidden from its reply until acpmux's next word on the message (a new row).
  const [steeredAt, setSteeredAt] = useState<number>();
  // Opening draws the menu again, so its moves read where the message waits now.
  const [, setOpened] = useState(0);
  const queued = row.queuedMessage;
  if (!queued || row.incoming?.kind !== "message") return null;
  const { promptId } = queued;
  const message = row.incoming.message;
  // The prompt as it waits, which Edit message puts in the composer.
  const text = message.raw;
  const fail = () => undefined;
  const at = act?.move ? act.position?.(promptId) : undefined;
  const item = (label: Parameters<typeof t>[0], onSelect: () => void, disabled = false) => (
    <MenuItem className="acpmux-quick-item" disabled={disabled} onSelect={onSelect}>
      {t(label)}
    </MenuItem>
  );
  const menu = (
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
          {act &&
            !queued.next &&
            steeredAt !== row.version &&
            item(
              "composer.queueSteer",
              () => void act.steer(promptId).then((ok) => ok && setSteeredAt(row.version), fail),
            )}
          {act && item("composer.queueEditMessage", () => void act.edit(promptId, text, row.images ?? []).catch(fail))}
          {act?.sideChat &&
            !row.images?.length &&
            item("composer.queueSideChat", () => void act.sideChat!(promptId, text).catch(fail))}
          {at &&
            item("composer.queueMoveUp", () => void act!.move!(promptId, at.index - 1).catch(fail), at.index === 0)}
          {at &&
            item(
              "composer.queueMoveDown",
              () => void act!.move!(promptId, at.index + 1).catch(fail),
              at.index >= at.count - 1,
            )}
          {item(queueing ? "composer.queueingOff" : "composer.queueingOn", () => setQueueing(!queueing))}
          {act && item("composer.queueDelete", () => void act.remove(promptId).catch(fail))}
        </MenuPopup>
      </Menu>
    </span>
  );
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
            {menu}
            {/* Last: a row's focus Copy (App.tsx) sits over the line's end, never over the menu. */}
            <span className="cv-received__queued">{t("message.readAfterTurn")}</span>
          </>
        }
        githubRepository={githubRepository}
      />
    </div>
  );
}

/// A message another agent steered into the running turn that the agent has not read yet
/// (`steer === "waiting"`): its received card's actions, then Send now in a ⋯ menu (`send_now`
/// with the steer's promptId, which stops the current step), and "Read after this step" last. No
/// spinner row and no dot (Leo, 2026-10-25).
export function SteerWaitingActions({ promptId, send }: { promptId?: string; send: (promptId: string) => void }) {
  const t = useT();
  return (
    <>
      {promptId && (
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
              <MenuItem className="acpmux-quick-item" onSelect={() => send(promptId)}>
                {t("steer.sendNow")}
              </MenuItem>
            </MenuPopup>
          </Menu>
        </span>
      )}
      <span className="cv-received__queued">{t("message.readAfterStep")}</span>
    </>
  );
}
