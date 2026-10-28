// Another agent's message waiting in the queue (a `QUEUED_MESSAGE` row, queuedMessages.ts): its
// received card, as it reads once delivered (collapsed in Minimal Mode as any is), with one quiet
// "Read after this turn" at the line's end, never a spinner or a pulsing dot (Leo, 2026-10-25). Its
// ⋯ menu keeps the queue row's actions: Steer (`send_now`, once), Edit message (into the composer,
// images too), Open in side chat (a message without images), Move up/down, queueing, Delete.
// A guest's prompt (design/chat-multiplayer.md, "Held message card"; Leo, 2026-10-28, on Theo's
// "Share with guest": "each message they send waits for you") is the same line from that person,
// held: Approve (primary) and Decline (quiet) in the line's action area, then "Waiting for you".
// Return approves it while the card has the focus. Approved, it waits as any queued message does;
// declined, it is one quiet line "Declined: <first line>" that opens on a click.
import { useContext, useState, type KeyboardEvent } from "react";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import type { AcpmuxRow, QueuedPromptImage } from "../model";
import { Menu, MenuButton, MenuItem, MenuPopup } from "../../../ui/Menu";
import { setQueueing, useQueueing } from "../queueing";
import { Face } from "../multiplayer/Faces";
import type { Participant } from "../multiplayer/participants";
import { PromptMarksSession } from "../threadMinimap/promptMarks";
import { ChevronRight } from "./icons";
import { IncomingMessageLine } from "./IncomingMessageCard";
import { recordedFiles } from "./UserBubble";
import type { FileAttachmentInfo } from "../FileAttachment";
import { messageOpened, setMessageOpened } from "./incomingOpened";
import { messagePreview, type IncomingMessage } from "./incomingMessage";
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
  /// The owner's Approve (true) or Decline of a guest's held prompt (`_acpmux/queue_approve`,
  /// `_acpmux/queue_decline`); absent when acpmux serves neither (initialize `queueApproval`).
  /// Approve names `revision`, the one the card was drawn with.
  answerHeld?: (promptId: string, approve: boolean, revision?: number) => Promise<HeldAnswer>;
};

/// How acpmux took an answer: sent; `stale`, the guest edited it since (the new text shows, and
/// the owner answers again); `gone`, it no longer waits (answered elsewhere); `failed`, anything else.
export type HeldAnswer = "ok" | "stale" | "gone" | "failed";

/// Where a held message's Approve and Decline sit: in the line's action area (`inline`, the pick),
/// in a compact bar under the message (`bar`), or in a ⋯ menu beside the label (`menu`). The
/// gallery compares them through `<html data-held-card-look>`; the app sets none.
export type HeldLook = "inline" | "bar" | "menu";
export function heldLook(root: { dataset: DOMStringMap } | undefined = globalThis.document?.documentElement): HeldLook {
  const value = root?.dataset.heldCardLook;
  return value === "bar" || value === "menu" ? value : "inline";
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
  const queueing = useQueueing();
  const act = useContext(TurnActionsContext).queuedMessages?.();
  // Steer goes once: hidden from its reply until acpmux's next word on the message (a new row).
  const [steeredAt, setSteeredAt] = useState<number>();
  // Opening draws the menu again, so its moves read where the message waits now.
  const [, setOpened] = useState(0);
  const queued = row.queuedMessage;
  if (!queued || row.incoming?.kind !== "message") return null;
  if (queued.declined) return <DeclinedLine row={row} person={queued.person} />;
  if (queued.person || queued.held) return <PersonMessageCard row={row} act={act} />;
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

/// Everything a held message sends beyond its text and images, so the owner approves what they
/// see: its resource links as a sent prompt draws them (UserBubble.tsx `recordedFiles`), and its
/// documents and audio as the same file chips (a sent prompt's own bubble has them in the
/// composer's attachments instead).
export function heldFiles(parts: AcpmuxRow["inlineParts"]): FileAttachmentInfo[] {
  const media = (parts ?? []).flatMap((part): FileAttachmentInfo[] =>
    (part.kind === "document" || part.kind === "audio") && part.companionOf === undefined
      ? [
          {
            name: part.name,
            ...(part.mimeType ? { mimeType: part.mimeType } : {}),
            ...(part.size ? { size: part.size } : {}),
          },
        ]
      : [],
  );
  return [...(recordedFiles(parts) ?? []), ...media];
}

/// A person's (a guest's) waiting prompt: held with Approve and Decline, or approved and waiting.
/// The owner changes nothing else of it (acpmux `queue.not_author`).
function PersonMessageCard({ row, act }: { row: AcpmuxRow; act?: QueuedMessageActionsValue }) {
  const t = useT();
  const queued = row.queuedMessage!;
  const message = (row.incoming as { message: IncomingMessage }).message;
  const { promptId, held, revision, updating } = queued;
  // Pressed and not answered yet: both buttons wait, so one click sends one answer. A refusal
  // says so quietly in the row's label (`note`), never a toast.
  const [answering, setAnswering] = useState(false);
  const [note, setNote] = useState<"stale" | "gone">();
  const answer = (approve: boolean) => {
    // Text and revision from different records: nothing is approved until the new text shows.
    if (!act?.answerHeld || answering || updating) return;
    setAnswering(true);
    setNote(undefined);
    void act.answerHeld(promptId, approve, revision).then((result) => {
      if (result === "stale" || result === "gone") setNote(result);
      if (result !== "ok" && result !== "gone") setAnswering(false);
    });
  };
  const answers = held && act?.answerHeld !== undefined;
  const look = heldLook();
  const button = (approve: boolean) => (
    <button
      type="button"
      className={approve ? "cv-held__approve" : "cv-held__decline"}
      disabled={answering || updating}
      onClick={() => answer(approve)}
    >
      {t(approve ? "queue.held.approve" : "queue.held.decline")}
    </button>
  );
  const menu = (
    <span className="cv-received-actions cv-received__queued-actions">
      <Menu>
        <MenuButton
          className="cv-iconbtn cv-iconbtn--compact"
          data-menu="held-message"
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
          <MenuItem
            className="acpmux-quick-item cv-held__primary"
            disabled={answering || updating}
            onSelect={() => answer(true)}
          >
            {t("queue.held.approve")}
          </MenuItem>
          <MenuItem className="acpmux-quick-item" disabled={answering || updating} onSelect={() => answer(false)}>
            {t("queue.held.decline")}
          </MenuItem>
        </MenuPopup>
      </Menu>
    </span>
  );
  // Return on the focused card approves it; never from a button or a link inside it.
  const onKeyDown = (event: KeyboardEvent<HTMLDivElement>) => {
    if (!answers || event.key !== "Enter" || event.target !== event.currentTarget) return;
    event.preventDefault();
    answer(true);
  };
  return (
    // oxlint-disable-next-line jsx-a11y/no-noninteractive-tabindex, jsx-a11y/no-static-element-interactions -- the held card takes the focus so Return approves it (design/chat-multiplayer.md)
    <div
      className="cv-incoming cv-held"
      data-queued-message={promptId}
      data-held={held || undefined}
      data-look={held ? look : undefined}
      tabIndex={held ? 0 : undefined}
      onKeyDown={onKeyDown}
    >
      <IncomingMessageLine
        id={row.id}
        message={message}
        person={queued.person}
        whole
        files={heldFiles(row.inlineParts)}
        images={row.images}
        onOpen={() => undefined}
        actions={
          <>
            {answers && look === "inline" && (
              <span className="cv-held__actions">
                {button(true)}
                {button(false)}
              </span>
            )}
            {answers && look === "menu" && menu}
            <span className="cv-received__queued">
              {t(
                updating && held
                  ? "queue.held.updating"
                  : note === "stale"
                    ? "queue.held.stale"
                    : note === "gone"
                      ? "queue.held.gone"
                      : held
                        ? "queue.held.waiting"
                        : "message.readAfterTurn",
              )}
            </span>
          </>
        }
      />
      {answers && look === "bar" && (
        <div className="cv-held__actions cv-held__bar">
          {button(true)}
          {button(false)}
        </div>
      )}
    </div>
  );
}

/// A guest's prompt the owner declined: one quiet line, "Declined: <first line>", that opens to the
/// whole text on a click and closes again; opened, it stays so while the page lasts (incomingOpened.ts).
function DeclinedLine({ row, person }: { row: AcpmuxRow; person?: Participant }) {
  const t = useT();
  const session = useContext(PromptMarksSession);
  const [open, setOpen] = useState(() => messageOpened(session, row.id));
  const text = row.text ?? "";
  const toggle = () => {
    setMessageOpened(session, row.id, !open);
    setOpen(!open);
  };
  return (
    <div className="cv-incoming cv-declined" data-declined-message={row.queuedMessage?.promptId}>
      <button type="button" className="cv-declined__line" aria-expanded={open} onClick={toggle}>
        {person && <Face person={person} size={14} />}
        <span className="cv-declined__text">{t("queue.held.declined", { preview: messagePreview(text) })}</span>
        <ChevronRight size={12} strokeWidth={1.4} className={`cv-rotor${open ? " is-open" : ""}`} />
      </button>
      {open && <div className="cv-received__body cv-declined__body selectable">{text}</div>}
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
