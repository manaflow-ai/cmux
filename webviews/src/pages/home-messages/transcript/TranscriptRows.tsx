// One transcript row as the Swift transcript draws it (RowDrawing): a centered time label, a group
// chat's sender name, a bubble (mine on the right in the sent colour, theirs on the left in the
// received one, the group's last with its tail), the Edited and Not Delivered labels, the Read and
// Delivered receipts, an unsent line and the typing bubble. A bubble's right-click menu has Copy,
// the tapbacks, and on a failed send Try Again and Delete.
import { memo, type ReactNode } from "react";
import { Spinner } from "../../../agent-session/acpmux/conversation/icons";
import { Markdown } from "../../../agent-session/acpmux/conversation/Markdown";
import { ContextMenu, type ContextMenuItem } from "../../../ui/ContextMenu";
import { MessageAttachments } from "../../home-channels/AttachmentViews";
import { Avatar } from "../../home-channels/Avatar";
import { partText } from "../../home-channels/model";
import type { HomeAttachment, HomeMessage, HomeParticipant } from "../../home-channels/types";
import type { Strings } from "../../shared/i18n";
import { ApprovalCard } from "../cards/approval/ApprovalCard";
import type { ApprovalDecisions } from "../cards/approval/approval";
import { HomeLinkChip } from "../cards/links/HomeLinkChip";
import { LinkPreviewCard, LocationCard, locationCopyText, mentionedText } from "../cards/parts/PartCards";
import type { LinkPreviewFetch } from "../cards/links/linkPreview";
import { formatDay, formatTime } from "./format";
import type { TranscriptRow } from "./rows";

/** The tapbacks, in Messages' order: the name sent back (`HomeReaction.tapback`) and its emoji. */
export const TAPBACKS = [
  { tapback: "love", value: "❤️" },
  { tapback: "like", value: "👍" },
  { tapback: "dislike", value: "👎" },
  { tapback: "laugh", value: "😂" },
  { tapback: "emphasize", value: "‼️" },
  { tapback: "question", value: "❓" },
] as const;

/** Link chips in people's plain text (Swift `HomeLinkChip`): the app's facts and opening. */
export interface RowLinks {
  fetchPreview: LinkPreviewFetch;
  onOpen(href: string): void;
}

export interface RowActions {
  onRetry?(key: string): void;
  onDiscard?(key: string): void;
  /** Cancel Upload on a send still going (MessagesLab PaneMenu's `canCancelSend`/`cancelSend`). */
  canCancelUpload?(key: string): boolean;
  onCancelUpload?(key: string): void;
  /** A tapback on a part: `value` is its emoji, `tapback` its name (sent again: taken back). */
  onReact?(message: HomeMessage, partIndex: number, value: string, tapback: string): void;
  onCopy?(text: string): void;
  /** Reply… (the native menu's): the message's thread opens, and a send there answers it. */
  onReply?(message: HomeMessage): void;
  links?: RowLinks;
  /** A Chief's permission cards: their state and the app's decision (absent: no buttons). */
  approvals?: ApprovalDecisions;
}

export interface TranscriptRowViewProps {
  row: TranscriptRow;
  me: string;
  strings: Strings;
  /** The day labels' "now" (the transcript's clock, one per render). */
  now: number;
  people: ReadonlyMap<string, HomeParticipant>;
  actions: RowActions;
  /** The message a link opened at: its bubbles are marked. */
  highlight?: string;
}

const PENDING = "pending:";

export const TranscriptRowView = memo(function TranscriptRowView({
  row,
  me,
  strings,
  now,
  people,
  actions,
  highlight,
}: TranscriptRowViewProps) {
  const { t } = strings;
  const style = row.gap ? { paddingTop: row.gap } : undefined;
  switch (row.kind) {
    case "older":
      return (
        <div className="mt-older" aria-busy={row.loading}>
          {row.loading && <Spinner size={14} loading />}
        </div>
      );
    case "separator":
      return (
        <div className="mt-separator" style={style}>
          <b>{formatDay(row.at, now, strings)}</b> {formatTime(row.at, strings)}
        </div>
      );
    case "name":
      return (
        <div className="mt-name" style={style}>
          {row.participant.name}
        </div>
      );
    case "label":
      return (
        <div className={`mt-label ${row.outgoing ? "out" : "in"} ${row.label}`} style={style}>
          {t(
            row.label === "edited" ? "label.edited" : row.label === "notKept" ? "label.notKept" : "label.notDelivered",
          )}
        </div>
      );
    case "unsent":
      return (
        <div className={`mt-unsent ${row.outgoing ? "out" : "in"}`} style={style}>
          {t(row.outgoing ? "row.unsent.mine" : "row.unsent.theirs")}
        </div>
      );
    case "receipt":
      return (
        <div className="mt-receipt" style={style}>
          <b>{t(row.receipt === "read" ? "receipt.read" : "receipt.delivered")}</b>
          {row.receipt === "read" && row.at !== undefined ? ` ${formatTime(row.at, strings)}` : ""}
        </div>
      );
    case "typing": {
      const names = row.participants.map((id) => people.get(id)?.name ?? id);
      const label = names.length === 1 ? strings.format("typing.one", names[0]!) : t("typing.many");
      return (
        <output className="mt-typing-row" style={style} aria-label={label}>
          <span className="mt-bubble in tail mt-typing" aria-hidden>
            <i />
            <i />
            <i />
          </span>
        </output>
      );
    }
    case "bubble":
      return (
        <BubbleRow
          row={row}
          me={me}
          strings={strings}
          actions={actions}
          highlighted={highlight !== undefined && row.message.id === highlight}
        />
      );
  }
});

function BubbleRow({
  row,
  me,
  strings,
  actions,
  highlighted,
}: {
  row: Extract<TranscriptRow, { kind: "bubble" }>;
  me: string;
  strings: Strings;
  actions: RowActions;
  highlighted: boolean;
}) {
  const { t } = strings;
  const { message, outgoing, delivery } = row;
  const head = row.parts[0];
  const media = head?.type === "attachment";
  const text = bubbleCopyText(row);
  const pendingKey = message.id.startsWith(PENDING) ? message.id.slice(PENDING.length) : undefined;
  const failed = delivery?.state === "failed";
  const committed = !pendingKey && !row.streaming;
  const items: ContextMenuItem[] = [];
  if (failed && pendingKey) {
    items.push({ id: "retry", label: t("home.menu.tryAgain"), onSelect: () => actions.onRetry?.(pendingKey) });
    items.push({
      id: "discard",
      label: t("home.menu.deleteFailed"),
      destructive: true,
      onSelect: () => actions.onDiscard?.(pendingKey),
    });
  } else if (pendingKey && actions.canCancelUpload?.(pendingKey)) {
    items.push({
      id: "cancelUpload",
      label: t("home.menu.cancelUpload"),
      onSelect: () => actions.onCancelUpload?.(pendingKey),
    });
  }
  if (committed && actions.onReply)
    items.push({
      id: "reply",
      label: t("menu.replyEllipsis"),
      separatorBefore: items.length > 0,
      onSelect: () => actions.onReply?.(message),
    });
  if (text)
    items.push({
      id: "copy",
      label: t("menu.copy"),
      separatorBefore: items.length > 0 && items.at(-1)?.id !== "reply",
      onSelect: () => actions.onCopy?.(text),
    });
  if (committed && actions.onReact)
    TAPBACKS.forEach((entry, index) => {
      const mine = row.reactions.some((reaction) => reaction.author === me && reaction.tapback === entry.tapback);
      items.push({
        id: `tapback.${entry.tapback}`,
        label: `${entry.value}  ${t(`tapback.${entry.tapback}`)}`,
        checked: mine,
        separatorBefore: index === 0 && items.length > 0,
        onSelect: () => actions.onReact?.(message, row.partIndex, entry.value, entry.tapback),
      });
    });
  const reactions = row.reactions.length > 0 && (
    <span className={`mt-tapbacks ${outgoing ? "out" : "in"}`} aria-label={t("menu.tapback")}>
      {[...new Set(row.reactions.map((reaction) => reaction.value))].map((value) => (
        <span
          key={value}
          className={`mt-tapback${row.reactions.some((r) => r.value === value && r.author === me) ? " mine" : ""}`}
        >
          {value}
        </span>
      ))}
    </span>
  );
  const card = cardOf(row, strings, actions);
  if (card)
    return bubbleRow(
      row,
      <div className={`mt-card${highlighted ? " highlighted" : ""}`} data-message={message.id}>
        {reactions}
        {card}
      </div>,
      items,
      failed && pendingKey ? pendingKey : undefined,
      actions,
      t,
    );
  // Text with mentions shows as written, its mentions marked (their offsets index it): never Markdown.
  const mentions = head?.type === "text" && head.mentions?.length ? head.mentions : undefined;
  const body: ReactNode = media ? (
    <MessageAttachments
      conversation={message.conversation}
      parts={row.parts as readonly HomeAttachment[]}
      strings={strings}
    />
  ) : mentions ? (
    <span className="mt-text">
      {mentionedText(
        text,
        mentions,
        () => undefined,
        (piece) => (actions.links ? linkedText(piece, actions.links) : piece),
      )}
    </span>
  ) : row.markdown && head?.type === "text" ? (
    <Markdown streaming={row.streaming}>{text}</Markdown>
  ) : (
    <span className="mt-text">{actions.links ? linkedText(text, actions.links) : text}</span>
  );
  const bubble = (
    <div
      className={[
        media ? "mt-media" : "mt-bubble",
        outgoing ? "out" : "in",
        row.tail && !media ? "tail" : "",
        delivery?.state === "sending" ? "sending" : "",
        failed ? "failed" : "",
        row.markdown ? "md" : "",
        highlighted ? "highlighted" : "",
      ]
        .filter(Boolean)
        .join(" ")}
      data-message={message.id}
    >
      {reactions}
      {body}
    </div>
  );
  return bubbleRow(row, bubble, items, failed && pendingKey ? pendingKey : undefined, actions, t);
}

/** What a bubble's Copy copies (Swift `HomeContentMenu.partItems`): its text; a link card its
 * address, a place its name and coordinates; media and a permission card nothing. */
export function bubbleCopyText(row: Extract<TranscriptRow, { kind: "bubble" }>): string {
  const head = row.parts[0];
  if (!head || head.type === "attachment" || row.approval) return "";
  if (head.type === "link_preview") return head.url;
  if (head.type === "location") return locationCopyText(head);
  return row.parts.map(partText).join("\n");
}

/** A bubble (or a card) in its row: the avatar column, the right-click menu, a failed send's mark. */
function bubbleRow(
  row: Extract<TranscriptRow, { kind: "bubble" }>,
  bubble: ReactNode,
  items: ContextMenuItem[],
  failedKey: string | undefined,
  actions: RowActions,
  t: Strings["t"],
) {
  return (
    <div
      className={`mt-bubble-row ${row.outgoing ? "out" : "in"}${row.indent ? " indent" : ""}`}
      style={row.gap ? { paddingTop: row.gap } : undefined}
    >
      {row.indent && (
        <span className="mt-avatar-col" aria-hidden>
          {row.avatar && <Avatar participant={row.avatar} size={28} />}
        </span>
      )}
      {items.length ? <ContextMenu items={items}>{bubble}</ContextMenu> : bubble}
      {failedKey && (
        <button
          type="button"
          className="mt-failed-mark"
          aria-label={t("home.menu.tryAgain")}
          title={t("label.notDelivered")}
          onClick={() => actions.onRetry?.(failedKey)}
        >
          !
        </button>
      )}
    </div>
  );
}

/** A part drawn as a card instead of a text bubble: a permission card, a link preview, a place. */
function cardOf(row: Extract<TranscriptRow, { kind: "bubble" }>, strings: Strings, actions: RowActions): ReactNode {
  const head = row.parts[0];
  if (head?.type === "question" && row.approval)
    return (
      <ApprovalCard
        message={row.message}
        partIndex={row.partIndex}
        question={head}
        strings={strings}
        {...(actions.approvals ? { decisions: actions.approvals } : {})}
      />
    );
  if (head?.type === "link_preview")
    return (
      <LinkPreviewCard
        conversation={row.message.conversation}
        part={head}
        {...(actions.links ? { onOpen: actions.links.onOpen } : {})}
      />
    );
  if (head?.type === "location") return <LocationCard part={head} />;
  return undefined;
}

/** Links in people's text: http(s) and cmux app links, without the punctuation that ends a sentence. */
const LINK = /\b(?:https?|cmux(?:-[a-z0-9]+)*):\/\/[^\s<>"]+/gi;
const TRAILING = /[.,;:!?)\]}'"]+$/;

/** `text` with each link drawn as its chip (the agent pane's web chip, or an app link's). */
export function linkedText(text: string, links: RowLinks): ReactNode[] {
  const out: ReactNode[] = [];
  let at = 0;
  for (const match of text.matchAll(LINK)) {
    const href = match[0].replace(TRAILING, "");
    if (!href) continue;
    const start = match.index;
    if (start > at) out.push(text.slice(at, start));
    out.push(
      <HomeLinkChip key={start} href={href} label={href} fetchPreview={links.fetchPreview} onOpen={links.onOpen} />,
    );
    at = start + href.length;
  }
  if (at < text.length) out.push(text.slice(at));
  return out;
}
