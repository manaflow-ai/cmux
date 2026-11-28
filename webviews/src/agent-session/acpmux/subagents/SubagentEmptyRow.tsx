import { useT } from "../i18n";
import type { RowProps } from "../rows/rowProps";
import "./SubagentEmptyRow.css";

/// A child with no rows to draw: nothing while its pane reads its own records
/// (subagentOwnLog.ts, `status: "loading"`), then one line saying it has none. No loading words and
/// no line explaining what would appear (Leo, 2026-11-27: "unnecesssary message and these take way
/// too long to load"). Both keep one line's height, so the swap moves nothing. Never a working
/// indicator for the agent itself.
export function SubagentEmptyRow({ row }: Pick<RowProps, "row">) {
  const t = useT();
  if (row.status === "loading") return <section className="cv-subagent-empty" aria-busy="true" />;
  return (
    <section className="cv-subagent-empty">
      <h3>{t("subagents.empty.title")}</h3>
    </section>
  );
}
