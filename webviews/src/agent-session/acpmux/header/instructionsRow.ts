// The chat menu's Edit CLAUDE.md row (cx-ncc.65, Claude desktop's project instructions): the app
// opens the chat folder's instructions file in a file tab, made empty first when the folder has
// none (`project.instructions`). Claude reads CLAUDE.md; Codex and the other harnesses read AGENTS.md.
// Add Files to Project (cx-ncc.67, Claude desktop's project knowledge): the app copies the files the
// user picks into the folder's .cmux/context/ and names them in that file (`project.addFiles`).
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
  const name = instructionsFile(chat.family);
  return {
    key: "instructions",
    label: t("chatMenu.editInstructions", { file: name }),
    icon: "file.text",
    onSelect: () => open(cwd, name),
  };
}

/// The instructions file a harness reads.
const instructionsFile = (family: string | undefined) => (family === "claude" ? "CLAUDE.md" : "AGENTS.md");

export function projectFilesRow(
  chat: { cwd: string | undefined; family: string | undefined },
  add: (cwd: string, name: string) => void,
  t: Translate = translate,
): Exclude<ChatMenuItem, "separator"> | undefined {
  const { cwd } = chat;
  if (!cwd || isAgentHome(cwd)) return undefined;
  return {
    key: "projectFiles",
    label: t("chatMenu.addProjectFiles"),
    icon: "composer.attach",
    onSelect: () => add(cwd, instructionsFile(chat.family)),
  };
}
