// A transcript bubble's right-click menu, in the native transcript's order (MessagesLabHome
// PaneMenu.swift `menu(at:)`): the link or path under the pointer, the tapbacks, Tapback Details…,
// Reply to Selection, Reply…, Attach Sticker…; Copy, Copy Link, Forward…; a video's Play/Pause and View Larger and an
// attachment's rows; Try Again and Delete on my failed send, else Retry Reply, else Cancel Upload;
// Share…; Delete.
// It reads only the row, what was under the pointer and the host's facts, and builds no state.
import type { ContextMenuItem } from "../../../ui/ContextMenu";
import { messageLink, partText } from "../../home-channels/model";
import type { HomeAttachment, HomeConversation, HomeMessage } from "../../home-channels/types";
import type { Strings } from "../../shared/i18n";
import { locationCopyText } from "../cards/parts/PartCards";
import type { ReplyQuote } from "./replyQuote";
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

const PENDING = "pending:";

/** What the app offers a bubble's menu (`cmux.home.messages.bubble.facts`, per conversation). */
export interface BubbleHostFacts {
  /** The build's link scheme (`cmux`, `cmux-dev`, `cmux-dev-<tag>`): Copy Link. Absent: no Copy Link. */
  linkScheme?: string;
  /** Forward… (the app asks which chat or agent). */
  forward: boolean;
  /** Share… (the system share picker). */
  share: boolean;
  /** Retry Reply: the Chief's own brain takes it (not a Cloud-hosted Chief). */
  retryReply: boolean;
  /** The file rows of a path link and an attachment (Open in Right Pane, Open With…, …). */
  files: boolean;
}

export const NO_BUBBLE_HOST: BubbleHostFacts = { forward: false, share: false, retryReply: false, files: false };

/** The host's file rows: what each runs on (`cmux.home.messages.bubble.file`). */
export type FileAction = "open" | "openWith" | "quickLook" | "reveal" | "copyPath" | "copy" | "saveAs";

/** A file a row acts on: a path link's path, or an attachment of a message. */
export type FileTarget =
  | { path: string }
  | { attachment: HomeAttachment; conversation: string; message: string; partIndex: number };

/** What was under the pointer when the menu opened. */
export interface BubblePointer {
  /** A web or app link (not a path). */
  href?: string;
  /** A path link's absolute path (`file:///…` or a bare `/…`). */
  path?: string;
  /** The words selected inside this bubble. */
  selection?: string;
  /** The selection as Reply to Selection's quote (one sent message's words). */
  quote?: ReplyQuote;
  /** The attachment under the pointer (a run of them shows several). */
  attachment?: HomeAttachment;
  /** A video under the pointer: whether it plays now. */
  video?: { playing: boolean };
}

/** The conversation facts a bubble's rows depend on. */
export interface BubbleContext {
  me: string;
  conversation: Pick<HomeConversation, "id" | "kind" | "participants">;
  /** Sends go (the owner is connected): tapbacks, Delete. */
  online: boolean;
  /** Someone types in the conversation (a Chief working): no Retry Reply. */
  typing: boolean;
  host: BubbleHostFacts;
}

export interface BubbleMenuActions {
  onRetry?(key: string): void;
  onDiscard?(key: string): void;
  /** Cancel Upload on a send still going (MessagesLab PaneMenu's `canCancelSend`/`cancelSend`). */
  canCancelUpload?(key: string): boolean;
  onCancelUpload?(key: string): void;
  onReact?(message: HomeMessage, partIndex: number, value: string, tapback?: string): void;
  onCopy?(text: string): void;
  onReply?(message: HomeMessage): void;
  /** Reply to Selection: the message's thread opens with the selected words quoted. */
  onReplyToSelection?(message: HomeMessage, quote: ReplyQuote): void;
  onOpenLink?(href: string): void;
  onDelete?(message: HomeMessage): void;
  onRetryReply?(message: HomeMessage): void;
  onForward?(text: string): void;
  onShare?(item: { text: string } | { url: string }): void;
  onFile?(action: FileAction, target: FileTarget): void;
  /** Tapback Details… and Attach Sticker…: the row shows its popover. */
  onTapbackDetails?(): void;
  onSticker?(): void;
  /** A video's Play/Pause and View Larger. */
  onVideo?(action: "toggle" | "larger"): void;
}

type Bubble = Extract<TranscriptRow, { kind: "bubble" }>;

/** What a bubble's Copy copies (Swift `HomeContentMenu.partItems`): its text; a link card its
 * address, a place its name and coordinates; media and a permission card nothing. */
export function bubbleCopyText(row: Extract<TranscriptRow, { kind: "bubble" }>): string {
  const head = row.parts[0];
  if (!head || head.type === "attachment" || row.approval) return "";
  if (head.type === "link_preview") return head.url;
  if (head.type === "location") return locationCopyText(head);
  return row.parts.map(partText).join("\n");
}

/** A one-to-one Chief chat (`HomeConversationSummary.kind(me:) == .chief`). */
function chiefChat(context: BubbleContext): boolean {
  return context.conversation.kind === "chief";
}

/** An agent's send through my CLI or MCP tool (HomeAgentSender: my message, keyed `agent~`). */
function agentSend(message: HomeMessage, me: string): boolean {
  return message.author === me && (message.clientMessageId ?? "").startsWith("agent~");
}

/** My committed message, kept by its owner. */
function committedMine(row: Bubble, context: BubbleContext): boolean {
  const { message } = row;
  return (
    message.author === context.me &&
    !message.id.startsWith(PENDING) &&
    !row.streaming &&
    message.seq > 0 &&
    !message.retracted
  );
}

/** Delete (HomeProjection+Delete `deletableMessage`): sends go, a one-to-one Chief chat, my committed
 * message with its owner id, not retracted, not a run's read-only row and not an agent's send. */
export function canDeleteMessage(row: Bubble, context: BubbleContext): boolean {
  return (
    context.online &&
    chiefChat(context) &&
    committedMine(row, context) &&
    !row.message.parts.some((part) => part.type === "work") &&
    !agentSend(row.message, context.me)
  );
}

/** Retry Reply (HomeProjection+Retry `canRetryChiefTurn`): the Chief's own brain, nobody typing, my
 * committed message in a one-to-one Chief chat. */
export function canRetryReply(row: Bubble, context: BubbleContext): boolean {
  return context.host.retryReply && !context.typing && chiefChat(context) && committedMine(row, context);
}

/** The rows of a path link or an attachment, as the host's file menu (FileActionsMenu) orders them. */
function fileItems(
  prefix: string,
  target: FileTarget,
  actions: BubbleMenuActions,
  t: Strings["t"],
  openLabel: string,
): ContextMenuItem[] {
  const run = (action: FileAction) => () => actions.onFile?.(action, target);
  return [
    { id: `${prefix}.open`, label: openLabel, symbol: "rectangle.righthalf.inset.filled", onSelect: run("open") },
    {
      id: `${prefix}.openWith`,
      label: t("files.menu.openWith"),
      symbol: "arrow.up.forward.app",
      onSelect: run("openWith"),
    },
    {
      id: `${prefix}.quickLook`,
      label: t("files.menu.quickLook"),
      symbol: "eye",
      separatorBefore: true,
      onSelect: run("quickLook"),
    },
    { id: `${prefix}.reveal`, label: t("files.menu.showInFinder"), symbol: "macwindow", onSelect: run("reveal") },
    { id: `${prefix}.copyPath`, label: t("files.menu.copyPath"), symbol: "link", onSelect: run("copyPath") },
  ];
}

/** The menu of `row` with `pointer` under the pointer. */
export function bubbleMenuItems(
  row: Bubble,
  pointer: BubblePointer,
  context: BubbleContext,
  actions: BubbleMenuActions,
  strings: Strings,
): ContextMenuItem[] {
  const { t } = strings;
  const { message } = row;
  const items: ContextMenuItem[] = [];
  let group = false;
  const add = (item: ContextMenuItem) => {
    items.push(group && items.length > 0 ? { ...item, separatorBefore: true } : item);
    group = false;
  };
  const separate = () => {
    group = true;
  };
  const pendingKey = message.id.startsWith(PENDING) ? message.id.slice(PENDING.length) : undefined;
  const committed = !pendingKey && !row.streaming && !message.retracted;
  const media = row.parts[0]?.type === "attachment";
  const text = bubbleCopyText(row);
  const plain = row.parts[0]?.type === "text";

  // A path link leads with the host's file rows; a web or app link with Open Link and Copy Link Address.
  if (pointer.path && context.host.files && actions.onFile) {
    fileItems("path", { path: pointer.path }, actions, t, t("files.menu.openInRightPane")).forEach((item) => add(item));
    separate();
  } else if (pointer.href) {
    const href = pointer.href;
    add({
      id: "link.open",
      label: t("home.menu.openLink"),
      symbol: "safari",
      onSelect: () => actions.onOpenLink?.(href),
    });
    add({
      id: "link.copy",
      label: t("home.menu.copyLinkAddress"),
      symbol: "link",
      onSelect: () => actions.onCopy?.(href),
    });
    separate();
  }
  // Tapbacks only while the owner takes them (offline: none).
  const canReact = committed && context.online && !!actions.onReact;
  if (canReact) {
    for (const entry of TAPBACKS) {
      const mine = row.reactions.some(
        (reaction) => reaction.author === context.me && reaction.tapback === entry.tapback,
      );
      add({
        id: `tapback.${entry.tapback}`,
        label: `${entry.value}  ${t(`tapback.${entry.tapback}`)}`,
        checked: mine,
        onSelect: () => actions.onReact?.(message, row.partIndex, entry.value, entry.tapback),
      });
    }
    separate();
  }
  if (committed && actions.onTapbackDetails)
    add({
      id: "tapbackDetails",
      label: t("menu.tapbackDetails"),
      symbol: "plus.magnifyingglass",
      onSelect: actions.onTapbackDetails,
    });
  // Reply to Selection (MessagesLab PaneMenu): words selected in this message, right before Reply….
  const quote = pointer.quote;
  if (committed && quote && actions.onReplyToSelection)
    add({
      id: "replyToSelection",
      label: t("home.message.replyToSelection"),
      symbol: "text.quote",
      onSelect: () => actions.onReplyToSelection?.(message, quote),
    });
  if (committed && actions.onReply)
    add({
      id: "reply",
      label: t("menu.replyEllipsis"),
      symbol: "arrowshape.turn.up.left",
      onSelect: () => actions.onReply?.(message),
    });
  if (canReact && actions.onSticker)
    add({ id: "sticker", label: t("menu.attachSticker"), symbol: "face.smiling", onSelect: actions.onSticker });
  separate();
  // Copy: the words selected in this bubble, else the part's copy (a link card's address, a place).
  if (text) {
    const words = pointer.selection?.trim() ? pointer.selection : text;
    add({ id: "copy", label: t("menu.copy"), symbol: "doc.on.doc", onSelect: () => actions.onCopy?.(words) });
  }
  const scheme = context.host.linkScheme;
  if (committed && scheme) {
    const link = messageLink(message.conversation, message.id, scheme);
    add({ id: "copyLink", label: t("home.message.copyLink"), symbol: "link", onSelect: () => actions.onCopy?.(link) });
  }
  // Forward… a text part only (PaneMenu: `case .text`).
  if (plain && text && committed && context.host.forward && actions.onForward)
    add({
      id: "forward",
      label: t("home.menu.forward"),
      symbol: "arrowshape.turn.up.right",
      onSelect: () => actions.onForward?.(text),
    });
  separate();
  // An attachment's own rows: a video plays in place; the file rows come from the host.
  const attachment =
    pointer.attachment ?? (media && row.parts.length === 1 ? (row.parts[0] as HomeAttachment) : undefined);
  if (media && attachment) {
    if (pointer.video && actions.onVideo) {
      add({
        id: "video.toggle",
        label: t(pointer.video.playing ? "home.video.pause" : "home.video.play"),
        symbol: pointer.video.playing ? "pause.fill" : "play.fill",
        onSelect: () => actions.onVideo?.("toggle"),
      });
      add({
        id: "video.larger",
        label: t("home.video.viewLarger"),
        symbol: "arrow.up.left.and.arrow.down.right",
        onSelect: () => actions.onVideo?.("larger"),
      });
    }
    if (committed && context.host.files && actions.onFile) {
      const partIndex = row.partIndex + Math.max(0, row.parts.indexOf(attachment));
      const target: FileTarget = { attachment, conversation: message.conversation, message: message.id, partIndex };
      add({
        id: "attachment.copy",
        label: t("menu.copy"),
        symbol: "doc.on.doc",
        onSelect: () => actions.onFile?.("copy", target),
      });
      add({
        id: "attachment.saveAs",
        label: t("home.attachment.saveAs"),
        symbol: "square.and.arrow.down",
        onSelect: () => actions.onFile?.("saveAs", target),
      });
      separate();
      fileItems("attachment", target, actions, t, t("files.menu.openInRightPane")).forEach((item) => add(item));
    }
    separate();
  }
  // My "Not Delivered" message: Try Again and Delete; else Retry Reply on my message to a Chief.
  if (delivery(row) === "failed" && pendingKey) {
    add({
      id: "retry",
      label: t("home.menu.tryAgain"),
      symbol: "arrow.clockwise",
      onSelect: () => actions.onRetry?.(pendingKey),
    });
    add({
      id: "discard",
      label: t("home.menu.deleteFailed"),
      symbol: "trash",
      destructive: true,
      onSelect: () => actions.onDiscard?.(pendingKey),
    });
    separate();
  } else if (actions.onRetryReply && canRetryReply(row, context)) {
    add({
      id: "retryReply",
      label: t("home.menu.retryReply"),
      symbol: "arrow.clockwise",
      onSelect: () => actions.onRetryReply?.(message),
    });
    separate();
  } else if (pendingKey && actions.canCancelUpload?.(pendingKey)) {
    add({
      id: "cancelUpload",
      label: t("home.menu.cancelUpload"),
      symbol: "xmark.circle",
      onSelect: () => actions.onCancelUpload?.(pendingKey),
    });
    separate();
  }
  // Share…: the message's text, or a link part's address.
  const shared = plain || row.parts[0]?.type === "link_preview" ? shareItem(text) : undefined;
  if (committed && shared && context.host.share && actions.onShare)
    add({
      id: "share",
      label: t("menu.share"),
      symbol: "square.and.arrow.up",
      onSelect: () => actions.onShare?.(shared),
    });
  // Delete on my committed message in a Chief chat: it leaves at once; a refusal brings it back.
  if (actions.onDelete && canDeleteMessage(row, context)) {
    separate();
    add({
      id: "delete",
      label: t("home.menu.deleteMessage"),
      symbol: "trash",
      destructive: true,
      onSelect: () => actions.onDelete?.(message),
    });
  }
  return items;
}

function delivery(row: Bubble): string | undefined {
  return row.delivery?.state;
}

/** What Share… shares (PaneMenu `shareItems`): a text part's text, or a lone link's address. */
function shareItem(text: string): { text: string } | { url: string } | undefined {
  if (!text) return undefined;
  const trimmed = text.trim();
  if (/^https?:\/\/\S+$/i.test(trimmed)) return { url: trimmed };
  return { text };
}
