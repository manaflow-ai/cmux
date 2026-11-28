import { useT } from "../i18n";
import type { RowProps } from "../rows/rowProps";
import "./SubagentEmptyRow.css";

/// A child with no rows to draw: blank while its pane reads its own records
/// (subagentOwnLog.ts, `status: "loading"`), then empty. Loading draws no words: the tab's own spinner
/// already says it is loading, and "Loading messages… / Messages and tool calls from this agent appear
/// here." was a message with nothing to act on (Leo, 2026-11-27: "unnecesssary message", ask-4646da8b19;
/// plans/cmux-next/status-notices/web.tsv: DELETE). The blank row keeps the empty row's height, so the
/// swap to rows or to empty moves nothing. Never a working indicator for the agent itself.
export function SubagentEmptyRow({ row }: Pick<RowProps, "row">) {
  const t = useT();
  if (row.status === "loading") return <section className="cv-subagent-empty" aria-busy="true" />;
  const title = t("subagents.empty.title");
  return (
    <section className="cv-subagent-empty" aria-label={title}>
      <h3>{title}</h3>
      <p>{t("subagents.empty.detail")}</p>
    </section>
  );
}
