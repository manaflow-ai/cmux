// One transcript row as the Swift transcript draws it (RowDrawing): a centered time label, a group
// chat's sender name, a bubble (mine on the right in the sent colour, theirs on the left in the
// received one, the group's last with its tail), the Edited and Not Delivered labels, the Read and
// Delivered receipts, an unsent line, the typing bubble and a Chief turn's agents (one pill each). A bubble's right-click menu has Copy,
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
import { HomeLinkChip } from "../cards/links/HomeLinkChip";
import { AgentPills } from "../cards/pills/AgentPills";
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
  /** A tapback on a part: `value` is its emoji, `tapback` its name (sent again: taken back). */
  onReact?(message: HomeMessage, partIndex: number, value: string, tapback: string): void;
  onCopy?(text: string): void;
  /** Retry Reply on my message in a Chief chat (absent: not offered now, as while the Chief answers). */
  onRetryChief?(message: HomeMessage): void;
  /** A drag on an attachment: the host drags the file out (`partIndex`: its part in the message). */
  onDragAttachment?(message: HomeMessage, part: HomeAttachment, partIndex: number): void;
  links?: RowLinks;
  /** The agents rows' pills: their words (the cards' table) and a click on one (`command`: ⌘ held). */
  agents?: { strings: Strings; open(peer: string, command: boolean): void };
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
          {t(row.label === "edited" ? "label.edited" : "label.notDelivered")}
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
    case "agents":
      return (
        <div className="mt-agents" style={style}>
          {actions.agents ? (
            <AgentPills row={row.row} strings={actions.agents.strings} onOpen={actions.agents.open} />
          ) : null}
        </div>
      );
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
  const media = row.parts[0]?.type === "attachment";
  const text = media ? "" : row.parts.map(partText).join("\n");
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
  }
  if (!failed && outgoing && committed && !message.retracted && actions.onRetryChief)
    items.push({ id: "retryChief", label: t("home.menu.retryReply"), onSelect: () => actions.onRetryChief?.(message) });
  if (text)
    items.push({
      id: "copy",
      label: t("menu.copy"),
      separatorBefore: items.length > 0,
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
  const body: ReactNode = media ? (
    <MessageAttachments
      conversation={message.conversation}
      parts={row.parts as readonly HomeAttachment[]}
      strings={strings}
      {...(actions.onDragAttachment
        ? {
            onDragOut: (part: HomeAttachment) => actions.onDragAttachment?.(message, part, message.parts.indexOf(part)),
          }
        : {})}
    />
  ) : row.markdown ? (
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
  return (
    <div
      className={`mt-bubble-row ${outgoing ? "out" : "in"}${row.indent ? " indent" : ""}`}
      style={row.gap ? { paddingTop: row.gap } : undefined}
    >
      {row.indent && (
        <span className="mt-avatar-col" aria-hidden>
          {row.avatar && <Avatar participant={row.avatar} size={28} />}
        </span>
      )}
      {items.length ? <ContextMenu items={items}>{bubble}</ContextMenu> : bubble}
      {failed && pendingKey && (
        <button
          type="button"
          className="mt-failed-mark"
          aria-label={t("home.menu.tryAgain")}
          title={t("label.notDelivered")}
          onClick={() => actions.onRetry?.(pendingKey)}
        >
          !
        </button>
      )}
    </div>
  );
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
