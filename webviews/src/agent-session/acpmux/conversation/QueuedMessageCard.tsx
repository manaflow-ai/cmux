// Another agent's message waiting in the queue (a `QUEUED_MESSAGE` row, queuedMessages.ts): its
// received line, as it reads once delivered, in the one group of messages that wait
// (PendingMessagesCard.tsx), with no "Read after this turn" (Leo, 2026-10-29: "why the fuck do you
// guys keep doing this fucking bullshit with the red after this turn?"). Its actions are a message's,
// never the person's queue row's (Leo, 2026-10-29: "WHY AM I SEEING TURN OFF QUEUING ON AGENT
// MESSAGES????"): ⋯ with Send now (into the running turn, `send_now`,
// once) and Dismiss (the agent never gets it), in one group as on a delivered message's line. No
// Edit message, Move up or down, or queueing switch: those are the person's own prompts'
// (ComposerQueue.tsx). The sender's chat opens from its name (IncomingMessageCard.tsx).
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
import { Face } from "../multiplayer/Faces";
import type { Participant } from "../multiplayer/participants";
import { PromptMarksSession } from "../threadMinimap/promptMarks";
import { ChevronRight } from "./icons";
import { IncomingMessageLine } from "./IncomingMessageCard";
import { recordedFiles } from "./UserBubble";
import type { FileAttachmentInfo } from "../FileAttachment";
import { messageOpened, setMessageOpened } from "./incomingOpened";
import { messagePreview, type IncomingMessage } from "./incomingMessage";
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
  /// The owner's Approve (true) or Decline of a guest's held prompt (`_acpmux/queue_approve`,
  /// `_acpmux/queue_decline`); absent when acpmux serves neither (initialize `queueApproval`).
  /// Approve names `revision`, the one the card was drawn with.
  answerHeld?: (promptId: string, approve: boolean, revision?: number) => Promise<HeldAnswer>;
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
  const act = useContext(TurnActionsContext).queuedMessages?.();
  // Send now goes once: hidden from its reply until acpmux's next word on the message (a new row).
  const [sentAt, setSentAt] = useState<number>();
  const queued = row.queuedMessage;
  if (!queued || row.incoming?.kind !== "message") return null;
  if (queued.declined) return <DeclinedLine row={row} person={queued.person} />;
  if (queued.person || queued.held) return <PersonMessageCard row={row} act={act} />;
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
    // oxlint-disable-next-line jsx-a11y/no-static-element-interactions -- the held card takes the focus so Return approves it (design/chat-multiplayer.md)
    <div
      className="cv-incoming cv-held"
      data-queued-message={promptId}
      data-held={held || undefined}
      data-look={held ? look : undefined}
      // oxlint-disable-next-line jsx-a11y/no-noninteractive-tabindex -- the held card takes the focus so Return approves it
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
/// (`steer === "waiting"`), in the group of messages that wait: its ⋯ in the message's own action
/// group (MessageActions.tsx ReceivedActions `more`), with Send now (`send_now` with the steer's
/// promptId, which stops the current step). No spinner row, no dot, and no "Read after this step"
/// tag: the group says the messages wait (Leo, 2026-10-25, 2026-10-29).
export function SteerWaitingActions({ promptId, send }: { promptId?: string; send: (promptId: string) => void }) {
  return <WaitingMessageMenu sendNow={promptId ? () => send(promptId) : undefined} />;
}
