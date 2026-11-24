// How many of a run's calls failed, after its summary in parentheses, as Claude Code desktop ends a
// run's header: "Finished 6 background tasks, ran 5 commands (4 failed)"
// (Leo, 2026-11-03: "claude code desktop's summarization of tool calls/parsing of them seem kinda
// good?"). It keeps the error tone a run's failure count already had; each failed call also says
// "Failed" on its own row (CommandRow.tsx).
// Used by a group's line (ToolGroupRow.tsx), a folded run's (ToolRun.tsx) and a message run's
// (MessageRunLine.tsx).
import { useT } from "../i18n";

export function FailedCount({ n }: { n: number }) {
  const t = useT();
  if (n <= 0) return null;
  return <span className="cv-tool__failed is-count">{` (${t("tools.failedCount", { n })})`}</span>;
}
