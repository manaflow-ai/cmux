// The agent pane's native context menu (CmuxNextAgentPane AgentPaneContextMenu) acts on the
// message under the pointer: on `contextmenu`, before WebKit asks the host for its menu, the page
// reports that message (its text, an agent reply's Markdown, its turn's fork point, Retry and its
// links) and the selected transcript text under the pointer to the host's `cmuxAgentContextMenu`
// handler, or null when there is neither. On an image that opens on click (`data-open-image`) the
// report adds `openImage`, and the menu's Open Image clicks it (`openReportedImage`). The host uses
// one report for one menu. On a code block, a command, a path or a link the report adds that
// `part` (menuParts.ts), even outside a prompt or reply (a tool row).
import { Lexer, lexer, type Token, walkTokens } from "marked";
import { turnRows } from "../diff";
import type { AcpmuxSnapshot } from "../model";
import { menuPartAt, type MenuPart } from "./menuParts";
import { retryHelps, sendCause } from "../sendFailure";
import { withoutSkillDollars } from "../slashCommands";

export const MESSAGE_MENU_HANDLER = "cmuxAgentContextMenu";

export type MessageMenuTarget = {
  text: string;
  markdown?: string;
  forkSeq?: number;
  /// The chat opens a side chat through `forkSeq` (the chat menu's New side chat, from this turn).
  sideChat?: true;
  /// A prompt that was not sent: its row, for Retry (`chat.retryPrompt`).
  retryRowId?: string;
  /// The message's web links and images, each once, for Open Link.
  links?: string[];
};

/// What the page reports on `contextmenu`: the message under the pointer, and the selected
/// transcript text when the pointer is inside it (Quote in Reply, Search the Web...).
export type MessageMenuReport = Partial<MessageMenuTarget> & {
  selection?: string;
  openImage?: true;
  /// The pointer is on an image (a reply's, one I sent, the gallery's): the menu's Copy Image,
  /// Save Image As…, Quick Look and Show in Finder act on it (imageMenuActions.ts).
  image?: true;
  part?: MenuPart;
  /// The message's More button (MessageActions.tsx MessageMore), in CSS px: the host opens the
  /// menu a right-click on the message opens under it, now (the report is the right-click's).
  popUp?: { left: number; top: number; right: number; bottom: number };
  /// Identifies the native popup until the host reports its dismissal.
  popupId?: string;
};

/// Whether acpmux can fork the chat at all here: it serves forks, the pane is connected and the
/// chat is on this computer (acpmux refuses the rest).
const forkServed = (snapshot: AcpmuxSnapshot) =>
  Boolean(snapshot.canFork) &&
  !snapshot.summary?.peer &&
  snapshot.connection !== "disconnected" &&
  !snapshot.connection.startsWith("connecting");

/// Whether a turn can be forked now: acpmux serves the fork (`forkServed`) and no turn is running.
/// The turn footer's Fork shows on the same rule. The whole chat forks while it works too
/// (`forkToTarget`).
export const canFork = (snapshot: AcpmuxSnapshot) => forkServed(snapshot) && !snapshot.isWorking;

/// Why Fork Conversation from the app (the palette's step, the chat's right-click menu, its
/// shortcut: `chat.forkTo`) cannot fork the chat now, or undefined when it can: "unavailable" when
/// acpmux, the connection or the chat's machine does not serve the fork, "nothingYet" before the
/// chat's first turn (a Claude chat with none has no conversation to copy). A working chat forks
/// now, as it is: the person never waits for its turn to end (2026-10-21).
export function forkRefusal(snapshot: AcpmuxSnapshot): "unavailable" | "nothingYet" | undefined {
  if (!forkServed(snapshot)) return "unavailable";
  if (!snapshot.isWorking && latestForkSeq(snapshot.rows) === undefined) return "nothingYet";
  return undefined;
}

/// What Fork Conversation forks: a working chat as it is now (`live`: acpmux copies its running
/// turn cut off there and leaves the chat's turn running), else the chat through its latest
/// finished turn. Undefined when there is nothing to fork yet.
export function forkToTarget(snapshot: AcpmuxSnapshot): { live: true } | { throughSeq: number } | undefined {
  if (snapshot.isWorking) return { live: true };
  const throughSeq = latestForkSeq(snapshot.rows);
  return throughSeq === undefined ? undefined : { throughSeq };
}

/// Whether every completed turn can be forked: acpmux forks a Claude or Codex chat through any of
/// them (`hub/fork_at.rs`, cx-yqiv, cx-a7r); other agents fork only at a chat's end.
export const forksAnyTurn = (family: string | undefined) => family === "claude" || family === "codex";

/// Every turn a fork can start from, newest first: its seq and the prompt that began it (on one
/// line). A steer later in the turn does not rename it, nor does a prompt that failed or is still
/// pending; a turn begun without text (an image only) is left out rather than shown under another
/// turn's prompt.
export function forkablePrompts(
  rows: readonly { kind: string; seq?: number; text?: string; failed?: boolean; pending?: boolean }[],
) {
  const prompts: { seq: number; text: string }[] = [];
  let prompt: string | undefined;
  for (const row of rows) {
    if (row.kind === "user" && (row.failed || row.pending)) continue;
    if (row.kind === "user" && prompt === undefined) prompt = row.text?.trim().replace(/\s+/g, " ") ?? "";
    else if (row.kind === "turnSummary") {
      if (row.seq !== undefined && prompt) prompts.push({ seq: row.seq, text: prompt });
      prompt = undefined;
    }
  }
  return prompts.reverse();
}

/// The chat menu's Fork submenu's earlier turns: up to eight, newest first, after From here (the
/// latest turn). The latest turn is left out by its seq, not by position: an image-only latest turn
/// is not in `forkablePrompts`, so the first entry is then an earlier turn.
export function earlierForkPrompts(
  rows: readonly { kind: string; seq?: number; text?: string; failed?: boolean; pending?: boolean }[],
) {
  const latest = latestForkSeq(rows);
  return forkablePrompts(rows)
    .filter((prompt) => prompt.seq !== latest)
    .slice(0, 8);
}

/// The latest completed turn's summary event: the one turn a fork goes through unless the chat
/// `forksAnyTurn` (`acp.session.fork` refuses another agent's earlier turn).
export function latestForkSeq(rows: readonly { kind: string; seq?: number }[]): number | undefined {
  for (let index = rows.length - 1; index >= 0; index -= 1) {
    const row = rows[index]!;
    if (row.kind === "turnSummary" && row.seq !== undefined) return row.seq;
  }
  return undefined;
}

/// The message a transcript row shows (`data-row-id`; a copy folded into "Worked for" ends in
/// `:fold`), or undefined for a row that is not a prompt or a reply. `sideChat`: the chat opens a
/// side chat (the chat menu shows New side chat), so a turn that forks opens one too.
export function messageMenuTarget(
  snapshot: AcpmuxSnapshot,
  rowId: string,
  sideChat = false,
): MessageMenuTarget | undefined {
  const id = rowId.endsWith(":fold") ? rowId.slice(0, -":fold".length) : rowId;
  const row = snapshot.rows.find((candidate) => candidate.id === id);
  if (!row?.text || (row.kind !== "user" && row.kind !== "assistant")) return undefined;
  const turnSeq = canFork(snapshot)
    ? turnRows(snapshot.rows, id).find((candidate) => candidate.kind === "turnSummary")?.seq
    : undefined;
  const forkSeq =
    turnSeq !== undefined && (forksAnyTurn(snapshot.summary?.family) || turnSeq === latestForkSeq(snapshot.rows))
      ? turnSeq
      : undefined;
  const target: MessageMenuTarget =
    // A prompt copies as its bubble reads: a Codex skill `/name`, not `/$name` as sent.
    row.kind === "user"
      ? { text: withoutSkillDollars(row.text, snapshot.commands) }
      : { text: plainText(row.text), markdown: row.text };
  if (forkSeq !== undefined) target.forkSeq = forkSeq;
  if (forkSeq !== undefined && sideChat) target.sideChat = true;
  // A prompt too large to send is refused the same way again: no Retry, Edit takes an attachment out.
  if (row.kind === "user" && row.failed && retryHelps(sendCause(row.delivery))) target.retryRowId = row.id;
  const links = webLinks(row.text);
  if (links.length > 0) target.links = links;
  return target;
}

/// The http(s) links and images in a message's Markdown (bare URLs too), each once, in reading
/// order. Anything else (javascript:, file:, relative paths) is not offered.
export function webLinks(markdown: string): string[] {
  const links: string[] = [];
  void walkTokens(lexer(markdown), (token) => {
    if (token.type !== "link" && token.type !== "image") return;
    const href = String(token.href);
    if (/^https?:\/\//i.test(href) && !links.includes(href)) links.push(href);
  });
  return links;
}

/// Markdown as a person reads it: the words, code and links' text without the syntax, one block
/// per paragraph, list items on their own lines.
export function plainText(markdown: string): string {
  return blocks(lexer(markdown)).join("\n\n").trim();
}

function blocks(tokens: Token[]): string[] {
  return tokens.flatMap((token): string[] => {
    switch (token.type) {
      case "space":
      case "hr":
        return [];
      case "code":
        return [token.text];
      case "list":
        return [
          (token.items as { tokens: Token[] }[])
            .map(
              (item, index) =>
                `${token.ordered ? `${(Number(token.start) || 1) + index}.` : "-"} ${blocks(item.tokens).join("\n")}`,
            )
            .join("\n"),
        ];
      case "blockquote":
        return blocks(token.tokens ?? []);
      case "table":
        return [
          [token.header, ...token.rows]
            .map((cells: { tokens: Token[] }[]) => cells.map((cell) => inline(cell.tokens)).join("\t"))
            .join("\n"),
        ];
      case "html":
        return token.text.replace(/<[^>]*>/g, "").trim() ? [token.text.replace(/<[^>]*>/g, "").trim()] : [];
      default:
        return "tokens" in token && token.tokens ? [inline(token.tokens)] : "text" in token ? [String(token.text)] : [];
    }
  });
}

/// One line of inline Markdown (a table cell) as a person reads it; `---` or `# x` stay text.
export function inlinePlainText(markdown: string): string {
  return inline(Lexer.lexInline(markdown));
}

function inline(tokens: Token[]): string {
  return tokens
    .map((token) => {
      switch (token.type) {
        case "br":
          return "\n";
        case "image":
          return token.text;
        case "html":
          return "";
        case "codespan":
        case "escape":
          return token.text;
        default:
          return "tokens" in token && token.tokens ? inline(token.tokens) : "text" in token ? String(token.text) : "";
      }
    })
    .join("");
}

type MessageSource = (rowId: string) => MessageMenuTarget | undefined;
let source: MessageSource | undefined;

/// The page's reader of its current transcript (App sets it once its client connects).
export function setMessageMenuSource(next: MessageSource | undefined) {
  source = next;
}

type Handler = { postMessage(body: unknown): void };

const webkitHandler = () =>
  (window as unknown as { webkit?: { messageHandlers?: Record<string, Handler | undefined> } }).webkit
    ?.messageHandlers?.[MESSAGE_MENU_HANDLER];
/// Where reports go: the handler `installMessageMenuReporter` was given.
let menuHandler: () => Handler | undefined = () => undefined;
let openPopup: { id: string; anchor: Element } | undefined;

function clearMessagePopup() {
  openPopup?.anchor.removeAttribute("data-popup-open");
  openPopup = undefined;
}

/// Whether a host shows this page's message menu (its More button would do nothing without one).
export const hasMessageMenuHost = () => menuHandler() !== undefined;

/// More (…) on row `rowId`'s action row: asks the host for the menu a right-click on that message
/// opens, with the same report, shown under `anchor`. False when the row is not a message or no
/// host shows the menu.
export function openForkMenu(throughSeq: number, anchor?: Element): boolean {
  const handler = menuHandler();
  if (!handler) return false;
  const { left, top, right, bottom } = (anchor ?? document.body).getBoundingClientRect();
  // Its opener stays lit while the destination menu is open, as More's does; the host reports the close.
  clearMessagePopup();
  const popupId = anchor ? crypto.randomUUID() : undefined;
  if (anchor && popupId) {
    openPopup = { id: popupId, anchor };
    anchor.setAttribute("data-popup-open", "");
  }
  try {
    handler.postMessage({
      forkDestinations: throughSeq,
      popUp: { left, top, right, bottom },
      ...(popupId ? { popupId } : {}),
    });
  } catch {
    clearMessagePopup();
    return false;
  }
  return true;
}

export function openMessageMenu(rowId: string, anchor: Element): boolean {
  if (anchor.closest("[data-read-only-transcript]")) return false;
  const message = source?.(rowId);
  const handler = menuHandler();
  if (!message || !handler) return false;
  reportedImage = undefined;
  reportedPicture = undefined;
  const { left, top, right, bottom } = anchor.getBoundingClientRect();
  clearMessagePopup();
  const popupId = crypto.randomUUID();
  openPopup = { id: popupId, anchor };
  anchor.setAttribute("data-popup-open", "");
  try {
    handler.postMessage({ ...message, popUp: { left, top, right, bottom }, popupId } satisfies MessageMenuReport);
  } catch {
    clearMessagePopup();
    return false;
  }
  return true;
}

let reportedImage: HTMLElement | undefined;
let reportedPicture: HTMLImageElement | undefined;

/// The image the last report named, for one image action: its source, its name (alt text) and the
/// file a reply read it from (`data-image-path`). Undefined when the report named none; it is used up.
export function takeReportedPicture(): { src: string; name: string; path?: string } | undefined {
  const picture = reportedPicture;
  reportedPicture = undefined;
  const src = picture?.currentSrc || picture?.getAttribute("src") || "";
  if (!picture || !src) return undefined;
  const path = picture.closest<HTMLElement>("[data-image-path]")?.getAttribute("data-image-path") || undefined;
  return { src, name: picture.getAttribute("alt") ?? "", ...(path ? { path } : {}) };
}

/// Open Image: opens the image the last report named as its click does; false when it named none.
export function openReportedImage(): boolean {
  const image = reportedImage;
  reportedImage = undefined;
  image?.click();
  return Boolean(image);
}

/// Reports the message under the pointer on every `contextmenu` in `doc` (capture, so a row that
/// stops the event still reports). Returns the remover.
export function installMessageMenuReporter(
  doc: Document,
  handler: () => Handler | undefined = webkitHandler,
): () => void {
  menuHandler = handler;
  const report = (event: Event) => {
    const target = event.target as Element | null;
    // A read-only transcript (a guest's) has no owner menu: nothing is reported from inside it.
    if (target?.closest?.("[data-read-only-transcript]")) return;
    const rowId = target?.closest?.("[data-row-id]")?.getAttribute("data-row-id");
    const message = (rowId && source?.(rowId)) || undefined;
    reportedImage = target?.closest?.<HTMLElement>("[data-open-image]") ?? undefined;
    const picture = reportedImage?.querySelector("img") ?? target?.closest?.("img") ?? undefined;
    reportedPicture = picture && (picture.currentSrc || picture.getAttribute("src")) ? picture : undefined;
    const selection = selectionAt(doc, target);
    const part = selection ? undefined : menuPartAt(target);
    const body: MessageMenuReport | null =
      message || selection || reportedImage || reportedPicture || part
        ? {
            ...message,
            ...(selection ? { selection } : {}),
            ...(reportedImage ? { openImage: true as const } : {}),
            ...(reportedPicture ? { image: true as const } : {}),
            ...(part ? { part } : {}),
          }
        : null;
    handler()?.postMessage(body);
  };
  const closed = (event: Event) => {
    if ((event as CustomEvent<unknown>).detail === openPopup?.id) clearMessagePopup();
  };
  doc.defaultView?.addEventListener("cmux-message-menu-closed", closed);
  doc.addEventListener("contextmenu", report, true);
  return () => {
    doc.removeEventListener("contextmenu", report, true);
    doc.defaultView?.removeEventListener("cmux-message-menu-closed", closed);
    if (menuHandler === handler) {
      menuHandler = () => undefined;
      clearMessagePopup();
    }
  };
}

/// The selected transcript text when the right-click is inside the selection; nothing for a
/// collapsed or blank selection, a right-click elsewhere, or text in the composer (an editable
/// field, whose own Cut, Copy and Paste the menu keeps).
function selectionAt(doc: Document, target: Element | null): string | undefined {
  const selection = doc.getSelection();
  if (!target || !selection || selection.isCollapsed || selection.rangeCount === 0) return undefined;
  const editable = '[contenteditable]:not([contenteditable="false"]), textarea, input';
  if (target.closest?.(editable)) return undefined;
  const range = selection.getRangeAt(0);
  // A range can cross from the transcript into the composer. Reporting it would offer Quote in
  // Reply / Ask About This with text the user did not select from the message, so reject any
  // selection whose endpoint is in an editable field just like a right-click in that field.
  const endpointIsEditable = (node: Node | null) => {
    const element = node?.nodeType === 1 ? (node as Element) : node?.parentElement;
    return Boolean(element?.closest?.(editable));
  };
  if (endpointIsEditable(selection.anchorNode) || endpointIsEditable(selection.focusNode)) return undefined;
  if (!range.intersectsNode(target)) return undefined;
  return selection.toString().trim() || undefined;
}
