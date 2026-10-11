// The chat menu's Edit CLAUDE.md row (cx-ncc.65, Claude desktop's project instructions): the app
// opens the chat folder's instructions file in a file tab, made empty first when the folder has
// none (`project.instructions`). Claude reads CLAUDE.md; Codex and the other harnesses read AGENTS.md.
import { type Translate, translate } from "../i18n";
import { isAgentHome } from "../sessionList";
import type { ChatMenuItem } from "./ChatHeaderTools";

export function instructionsRow(
  chat: { cwd: string | undefined; family: string | undefined },
  open: (cwd: string, name: string) => void,
  t: Translate = translate,
): Exclude<ChatMenuItem, "separator"> | undefined {
  const { cwd } = chat;
  // Only a project folder on this Mac: a private agent-home folder is not a project.
  if (!cwd || isAgentHome(cwd)) return undefined;
  const name = chat.family === "claude" ? "CLAUDE.md" : "AGENTS.md";
  return {
    key: "instructions",
    label: t("chatMenu.editInstructions", { file: name }),
    icon: "file.text",
    onSelect: () => open(cwd, name),
  };
}
