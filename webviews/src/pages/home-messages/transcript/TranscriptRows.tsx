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

export interface RowActions {
  onRetry?(key: string): void;
  onDiscard?(key: string): void;
  /** A tapback on a part: `value` is its emoji, `tapback` its name (sent again: taken back). */
  onReact?(message: HomeMessage, partIndex: number, value: string, tapback: string): void;
  onCopy?(text: string): void;
}

export interface TranscriptRowViewProps {
  row: TranscriptRow;
  me: string;
  strings: Strings;
  /** The day labels' "now" (the transcript's clock, one per render). */
  now: number;
  people: ReadonlyMap<string, HomeParticipant>;
  actions: RowActions;
}

const PENDING = "pending:";

export const TranscriptRowView = memo(function TranscriptRowView({
  row,
  me,
  strings,
  now,
  people,
  actions,
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
    case "bubble":
      return <BubbleRow row={row} me={me} strings={strings} actions={actions} />;
  }
});

function BubbleRow({
  row,
  me,
  strings,
  actions,
}: {
  row: Extract<TranscriptRow, { kind: "bubble" }>;
  me: string;
  strings: Strings;
  actions: RowActions;
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
    />
  ) : row.markdown ? (
    <Markdown streaming={row.streaming}>{text}</Markdown>
  ) : (
    <span className="mt-text">{text}</span>
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
