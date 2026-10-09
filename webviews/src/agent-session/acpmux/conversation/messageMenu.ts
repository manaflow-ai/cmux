// The agent pane's native context menu (CmuxNextAgentPane AgentPaneContextMenu) acts on the
// message under the pointer: on `contextmenu`, before WebKit asks the host for its menu, the page
// reports that message (its text, an agent reply's Markdown, and its turn's fork point) to the
// host's `cmuxAgentContextMenu` handler, or null when the pointer is on neither a message nor an
// image. On an image that opens on click (`data-open-image`) the report adds `openImage`, and the
// menu's Open Image clicks it (`openReportedImage`). The host uses one report for one menu.
import { lexer, type Token } from "marked";
import { turnRows } from "../diff";
import type { AcpmuxSnapshot } from "../model";

export const MESSAGE_MENU_HANDLER = "cmuxAgentContextMenu";

export type MessageMenuTarget = { text: string; markdown?: string; forkSeq?: number };

type MenuReport = Partial<MessageMenuTarget> & { openImage?: true };

/// Whether a turn can be forked now: acpmux serves forks and the pane is connected (the turn
/// footer's Fork shows on the same rule).
export const canFork = (snapshot: AcpmuxSnapshot) =>
  Boolean(snapshot.canFork) && snapshot.connection !== "disconnected" && !snapshot.connection.startsWith("connecting");

/// The message a transcript row shows (`data-row-id`; a copy folded into "Worked for" ends in
/// `:fold`), or undefined for a row that is not a prompt or a reply.
export function messageMenuTarget(snapshot: AcpmuxSnapshot, rowId: string): MessageMenuTarget | undefined {
  const id = rowId.endsWith(":fold") ? rowId.slice(0, -":fold".length) : rowId;
  const row = snapshot.rows.find((candidate) => candidate.id === id);
  if (!row?.text || (row.kind !== "user" && row.kind !== "assistant")) return undefined;
  const forkSeq = canFork(snapshot)
    ? turnRows(snapshot.rows, id).find((candidate) => candidate.kind === "turnSummary")?.seq
    : undefined;
  const base = row.kind === "user" ? { text: row.text } : { text: plainText(row.text), markdown: row.text };
  return forkSeq === undefined ? base : { ...base, forkSeq };
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

let reportedImage: HTMLElement | undefined;

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
  handler: () => Handler | undefined = () =>
    (window as unknown as { webkit?: { messageHandlers?: Record<string, Handler | undefined> } }).webkit
      ?.messageHandlers?.[MESSAGE_MENU_HANDLER],
): () => void {
  const report = (event: Event) => {
    const target = event.target as Element | null;
    const rowId = target?.closest?.("[data-row-id]")?.getAttribute("data-row-id");
    const message = (rowId && source?.(rowId)) || undefined;
    reportedImage = target?.closest?.<HTMLElement>("[data-open-image]") ?? undefined;
    const body: MenuReport | undefined = reportedImage ? { ...message, openImage: true } : message;
    handler()?.postMessage(body ?? null);
  };
  doc.addEventListener("contextmenu", report, true);
  return () => doc.removeEventListener("contextmenu", report, true);
}
