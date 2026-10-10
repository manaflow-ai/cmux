// The chat menu's Copy submenu, as in ChatGPT: the chat's link, the last answer, and the whole
// chat as Markdown (each prompt a quote, each answer as written, turns split by a rule).
import { type Translate, translate } from "../i18n";
import type { AcpmuxRow } from "../model";
import { SHORTCUT_ACTIONS } from "../shortcuts";
import type { ChatMenuChild, ChatMenuItem } from "./ChatHeaderTools";

export function copyRow(
  chat: { link: string | undefined; rows: readonly AcpmuxRow[] },
  copy: (text: string) => void,
  t: Translate = translate,
): Exclude<ChatMenuItem, "separator"> | undefined {
  const { link } = chat;
  const response = lastResponse(chat.rows);
  const markdown = chatMarkdown(chat.rows);
  const children: ChatMenuChild[] = [];
  if (link)
    children.push({
      key: "copyLink",
      label: t("chatMenu.copyLink"),
      shortcutAction: SHORTCUT_ACTIONS.copyTabLink,
      onSelect: () => copy(link),
    });
  if (response)
    children.push({ key: "copyResponse", label: t("chatMenu.copyResponse"), onSelect: () => copy(response) });
  if (markdown)
    children.push({ key: "copyMarkdown", label: t("chatMenu.copyMarkdown"), onSelect: () => copy(markdown) });
  if (!children.length) return undefined;
  return { key: "copy", label: t("chatMenu.copy"), icon: "action.copy", children };
}

const text = (row: AcpmuxRow) => row.text?.trim() ?? "";

/// The answer after the last prompt: its text rows, in order.
function lastResponse(rows: readonly AcpmuxRow[]): string {
  let start = rows.length;
  while (start > 0 && rows[start - 1].kind !== "user") start--;
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
    if (!body) continue;
    if (row.kind === "user") {
      if (blocks.length) blocks.push("---");
      blocks.push(body.replace(/^/gm, "> "));
    } else if (row.kind === "assistant") {
      blocks.push(body);
    }
  }
  return blocks.join("\n\n");
}
