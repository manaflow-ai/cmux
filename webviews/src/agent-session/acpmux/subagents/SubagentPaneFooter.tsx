// A subagent's own pane ends in one quiet line where the chat's composer would be: the pane shows
// the subagent read only, and the chat it belongs to takes messages. The pane is a tab on the
// chat's session (subagents/subagentPanes.ts), so a composer there drew the chat's queue and pull
// request bars and sent its prompts to the chat (Leo 2026-10-20).
import { useT } from "../i18n";

export function SubagentPaneFooter({ chat }: { chat: string }) {
  const t = useT();
  return <p className="cv-subagent-pane-footer">{t("subagents.paneReadOnly", { name: chat })}</p>;
}
