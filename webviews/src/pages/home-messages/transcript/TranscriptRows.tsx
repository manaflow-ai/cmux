// One transcript row as the Swift transcript draws it (RowDrawing): a centered time label, a group
// chat's sender name, a bubble (mine on the right in the sent colour, theirs on the left in the
// received one, the group's last with its tail), the Edited and Not Delivered labels, the Read and
// Delivered receipts, an unsent line and the typing bubble. A bubble's right-click menu is the
// native transcript's (bubbleMenu.ts), built from what was under the pointer when it opened.
import { memo, useContext, useRef, useState, type MouseEvent as ReactMouseEvent, type ReactNode } from "react";
import { Spinner } from "../../../agent-session/acpmux/conversation/icons";
import { Markdown } from "../../../agent-session/acpmux/conversation/Markdown";
import { ContextMenu, type ContextMenuItem } from "../../../ui/ContextMenu";
import { Popover } from "../../../ui/Popover";
import type { EmojiTable } from "../../../icon-picker/emojiData";
import { AttachmentOpenContext, MessageAttachments } from "../../home-channels/AttachmentViews";
import { EmojiPicker, loadEmoji } from "../../home-channels/EmojiPicker";
import { Avatar } from "../../home-channels/Avatar";
import type { HomeAttachment, HomeMessage, HomePart, HomeParticipant } from "../../home-channels/types";
import type { Strings } from "../../shared/i18n";
import { ApprovalCard } from "../cards/approval/ApprovalCard";
import type { ApprovalDecisions } from "../cards/approval/approval";
import { HomeLinkChip } from "../cards/links/HomeLinkChip";
import { LinkPreviewCard, LocationCard, mentionedText } from "../cards/parts/PartCards";
import type { LinkPreviewFetch } from "../cards/links/linkPreview";
import { formatDay, formatTime } from "./format";
import {
  bubbleCopyText,
  bubbleMenuItems,
  type BubbleContext,
  type BubbleMenuActions,
  type BubblePointer,
  NO_BUBBLE_HOST,
} from "./bubbleMenu";
import { selectionQuote } from "./replyQuote";
import type { TranscriptRow } from "./rows";

export { TAPBACKS, bubbleCopyText } from "./bubbleMenu";

/** Link chips in people's plain text (Swift `HomeLinkChip`): the app's facts and opening. */
export interface RowLinks {
  fetchPreview: LinkPreviewFetch;
  onOpen(href: string): void;
}

export interface RowActions extends Omit<
  BubbleMenuActions,
  "onTapbackDetails" | "onSticker" | "onVideo" | "onOpenLink"
> {
  /** A tapback on a part: `value` is its emoji, `tapback` its name (sent again: taken back); an
   * emoji from Attach Sticker… has no name. */
  onReact?(message: HomeMessage, partIndex: number, value: string, tapback?: string): void;
  /** Reply… (the native menu's): the message's thread opens, and a send there answers it. */
  onReply?(message: HomeMessage): void;
  /** "N Replies" under a message: its thread (or, in a thread, its branch) opens. */
  onOpenReplies?(message: string): void;
  /** A drag on an attachment: the host drags the file out (`partIndex`: its part in the message). */
  onDragAttachment?(message: HomeMessage, part: HomeAttachment, partIndex: number): void;
  links?: RowLinks;
  /** The conversation's facts as the menu opens (read then, so a change re-renders no row). */
  context?(): BubbleContext;
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
    case "replies":
      return (
        <div className={`mt-replies-row ${row.outgoing ? "out" : "in"}${row.indent ? " indent" : ""}`} style={style}>
          <button type="button" className="mt-replies" onClick={() => actions.onOpenReplies?.(row.root)}>
            {row.count === 1 ? t("label.replies.one") : strings.format("label.replies", String(row.count))}
          </button>
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
          people={people}
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
  people,
  highlighted,
}: {
  row: Extract<TranscriptRow, { kind: "bubble" }>;
  me: string;
  strings: Strings;
  actions: RowActions;
  people: ReadonlyMap<string, HomeParticipant>;
  highlighted: boolean;
}) {
  const { t } = strings;
  const { message, outgoing, delivery } = row;
  const head = row.parts[0];
  const media = head?.type === "attachment";
  const text = bubbleCopyText(row);
  const pendingKey = message.id.startsWith(PENDING) ? message.id.slice(PENDING.length) : undefined;
  const failed = delivery?.state === "failed";
  // What was under the pointer when the menu opened (read in the capture phase, before the menu's
  // own handler reads its rows), and the popover a row opened (Tapback Details…, Attach Sticker…).
  const [pointer, setPointer] = useState<BubblePointer>({});
  const [popover, setPopover] = useState<"details" | "sticker">();
  const [emoji, setEmoji] = useState<EmojiTable>();
  const box = useRef<HTMLDivElement | null>(null);
  const video = useRef<HTMLVideoElement | null>(null);
  const opener = useContext(AttachmentOpenContext);
  const context = actions.context?.() ?? {
    me,
    conversation: { id: message.conversation, kind: "direct", participants: [] },
    online: true,
    typing: false,
    host: NO_BUBBLE_HOST,
  };
  const items = bubbleMenuItems(
    row,
    pointer,
    context,
    {
      ...actions,
      onOpenLink: actions.links?.onOpen,
      onTapbackDetails: () => setPopover("details"),
      onSticker: () => {
        setPopover("sticker");
        void loadEmoji().then(setEmoji, () => undefined);
      },
      onVideo: (action) => {
        const element = video.current;
        if (!element) return;
        // View Larger: the page's video viewer, else the player's own full screen.
        const shown = pointer.attachment;
        if (action === "larger" && opener && shown) opener.openVideo(message.conversation, shown);
        else if (action === "larger") void element.requestFullscreen?.().catch(() => undefined);
        else if (element.paused) void element.play().catch(() => undefined);
        else element.pause();
      },
    },
    strings,
  );
  const onContextMenuCapture = (event: ReactMouseEvent) => {
    const read = readPointer(event.target, box.current, row.parts);
    video.current = read.element;
    const quote = selectionQuote(document, message.id);
    setPointer(quote ? { ...read.pointer, quote } : read.pointer);
  };
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
  // Tapback Details… and Attach Sticker…: their popover at the bubble.
  const popovers = (
    <>
      {popover === "details" && (
        <Popover
          open
          onOpenChange={(open) => !open && setPopover(undefined)}
          anchor={box.current}
          side="top"
          label={t("tapback.details.title")}
          className="mt-tapback-details"
        >
          <strong>{t("tapback.details.title")}</strong>
          {row.reactions.length === 0 ? (
            <p>{t("tapback.details.none")}</p>
          ) : (
            <ul>
              {row.reactions.map((reaction, index) => (
                <li key={`${reaction.author}:${reaction.value}:${index}`}>
                  {reaction.value}
                  {"  "}
                  {people.get(reaction.author)?.name ?? reaction.author}
                </li>
              ))}
            </ul>
          )}
        </Popover>
      )}
      {popover === "sticker" && (
        <EmojiPicker
          anchor={box.current}
          {...(emoji ? { emoji } : {})}
          strings={strings}
          onPick={(value) => {
            setPopover(undefined);
            actions.onReact?.(message, row.partIndex, value);
          }}
          onClose={() => setPopover(undefined)}
        />
      )}
    </>
  );
  const card = cardOf(row, strings, actions);
  if (card)
    return bubbleRow(
      row,
      <div
        className={`mt-card${highlighted ? " highlighted" : ""}`}
        data-message={message.id}
        ref={box}
        onContextMenuCapture={onContextMenuCapture}
      >
        {reactions}
        {card}
      </div>,
      items,
      failed && pendingKey ? pendingKey : undefined,
      actions,
      t,
      popovers,
    );
  // Text with mentions shows as written, its mentions marked (their offsets index it): never Markdown.
  const mentions = head?.type === "text" && head.mentions?.length ? head.mentions : undefined;
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
      ref={box}
      // The menu's subject, read before the menu host's own handler builds its rows (React renders
      // the capture phase's update first).
      onContextMenuCapture={onContextMenuCapture}
    >
      {reactions}
      {body}
    </div>
  );
  return bubbleRow(row, bubble, items, failed && pendingKey ? pendingKey : undefined, actions, t, popovers);
}

/** A bubble (or a card) in its row: the avatar column, the right-click menu, a failed send's mark. */
function bubbleRow(
  row: Extract<TranscriptRow, { kind: "bubble" }>,
  bubble: ReactNode,
  items: ContextMenuItem[],
  failedKey: string | undefined,
  actions: RowActions,
  t: Strings["t"],
  popovers: ReactNode,
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
      {items.length ? (
        <ContextMenu items={items} selection="menu">
          {bubble}
        </ContextMenu>
      ) : (
        bubble
      )}
      {popovers}
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

/** What the right-click landed on inside a bubble: a link or path, the words selected in it, the
 * attachment and a video there. */
export function readPointer(
  target: EventTarget | null,
  bubble: HTMLElement | null,
  parts: readonly HomePart[],
): { pointer: BubblePointer; element: HTMLVideoElement | null } {
  const element = target instanceof Element ? target : null;
  const pointer: BubblePointer = {};
  const anchor = element?.closest<HTMLAnchorElement>("a[href]:not([download])");
  const href = anchor?.getAttribute("href") ?? "";
  if (href.startsWith("file://")) {
    try {
      pointer.path = decodeURIComponent(new URL(href).pathname);
    } catch {
      // Not a path the host can open: no file rows.
    }
  } else if (href.startsWith("/")) pointer.path = href;
  else if (href && !href.startsWith("#") && !href.startsWith("blob:") && !href.startsWith("data:")) pointer.href = href;
  const selection = typeof window !== "undefined" ? window.getSelection() : null;
  if (bubble && selection && !selection.isCollapsed && selection.anchorNode && bubble.contains(selection.anchorNode)) {
    const words = selection.toString();
    if (words.trim()) pointer.selection = words;
  }
  const tile = element?.closest<HTMLElement>("[data-attachment]");
  const hash = tile?.dataset.attachment;
  const attachment = hash
    ? parts.find((part): part is HomeAttachment => part.type === "attachment" && part.hash === hash)
    : undefined;
  if (attachment) pointer.attachment = attachment;
  const player = tile?.querySelector("video") ?? null;
  if (player) pointer.video = { playing: !player.paused };
  return { pointer, element: player };
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
