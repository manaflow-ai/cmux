// The chat menu's Copy submenu, as in ChatGPT: the chat's link, the last answer, the whole chat as
// Markdown (each prompt a quote, each answer as written, turns split by a rule), and its session id;
// Save as Markdown writes that same Markdown to a file the person picks.
import { type Translate, translate } from "../i18n";
import type { AcpmuxRow } from "../model";
import { SHORTCUT_ACTIONS } from "../shortcuts";
import type { ChatMenuChild, ChatMenuItem } from "./ChatHeaderTools";
import { sliceWhole } from "../../../ui/wholeChars";

export function copyRow(
  chat: { link: string | undefined; rows: readonly AcpmuxRow[]; sessionId?: string },
  copy: (text: string) => void,
  t: Translate = translate,
  copyFullConversation?: () => Promise<string | null>,
  saveMarkdown?: () => void,
): Exclude<ChatMenuItem, "separator"> | undefined {
  const { link, rows, sessionId } = chat;
  // The menu's rows are read on every render: only check here, build the text on selection.
  const answered = rows.some((row) => row.kind === "assistant" && text(row));
  const children: ChatMenuChild[] = [];
  if (link)
    children.push({
      key: "copyLink",
      label: t("chatMenu.copyLink"),
      shortcutAction: SHORTCUT_ACTIONS.copyTabLink,
      onSelect: () => copy(link),
    });
  if (answered && lastResponse(rows))
    children.push({ key: "copyResponse", label: t("chatMenu.copyResponse"), onSelect: () => copy(lastResponse(rows)) });
  if (answered)
    children.push({
      key: "copyMarkdown",
      label: t("chatMenu.copyMarkdown"),
      onSelect: () => {
        if (!copyFullConversation) {
          copy(chatMarkdown(rows));
          return;
        }
        void copyFullConversation().then((markdown) => {
          if (markdown) copy(markdown);
        });
      },
    });
  if (answered && saveMarkdown)
    children.push({ key: "saveMarkdown", label: t("chatMenu.saveMarkdown"), onSelect: saveMarkdown });
  if (sessionId)
    children.push({ key: "copySessionId", label: t("chatMenu.copySessionId"), onSelect: () => copy(sessionId) });
  if (!children.length) return undefined;
  return { key: "copy", label: t("chatMenu.copy"), icon: "action.copy", children };
}

const text = (row: AcpmuxRow) => row.text?.trim() ?? "";
/// A prompt the agent got: not one still sending, failed, or queued behind a harness switch.
const sent = (row: AcpmuxRow) =>
  row.kind === "user" && !row.pending && !row.failed && !row.queued && row.incoming?.kind !== "hidden";

/// The answer after the last sent prompt: its text rows, in order.
function lastResponse(rows: readonly AcpmuxRow[]): string {
  let start = rows.length;
  while (start > 0 && !sent(rows[start - 1])) start--;
  return rows
    .slice(start)
    .filter((row) => row.kind === "assistant")
    .map(text)
    .filter(Boolean)
    .join("\n\n");
}

function chatMarkdown(rows: readonly AcpmuxRow[]): string {
  const blocks: string[] = [];
  for (const row of rows) {
    const body = text(row);
    if (sent(row)) {
      if (blocks.length) blocks.push("---");
      // A prompt of attachments alone still starts its turn.
      if (body) blocks.push(body.replace(/^/gm, "> "));
    } else if (row.kind === "assistant" && body) {
      blocks.push(body);
    }
  }
  return blocks.join("\n\n");
}

/// A stable export for the native command palette. Role headings make a copied chat readable in a
/// plain editor, while tool calls stay as short, title-only lines instead of leaking their inputs or
/// outputs into a clipboard action. Recorded exports pass rows folded from the complete event log,
/// including older turns that the live transcript has not loaded.
export function conversationMarkdown(rows: readonly AcpmuxRow[]): string {
  const blocks: string[] = [];
  for (const row of rows) {
    const body = text(row);
    if (sent(row)) {
      if (body || row.images?.length) blocks.push(`**User:**\n${body || "(attachment)"}`);
    } else if (row.kind === "assistant" && body) {
      blocks.push(`**Assistant:**\n${body}`);
    }
    const tools = (row.items ?? [])
      .map((item) => item.tool?.title.trim())
      .filter((title): title is string => !!title)
      .map((title) => {
        const compact = title.replace(/\s+/gu, " ");
        const short = compact.length > 160 ? `${sliceWhole(compact, 157)}…` : compact;
        return `- Tool: ${short}`;
      });
    if (tools.length) blocks.push(...tools);
  }
  return blocks.join("\n\n");
}
