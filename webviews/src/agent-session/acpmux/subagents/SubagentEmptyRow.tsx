import { useT } from "../i18n";
import type { RowProps } from "../rows/rowProps";
import "./SubagentEmptyRow.css";

/// A child with no rows to draw: loading while its pane reads its own records
/// (subagentOwnLog.ts, `status: "loading"`), then empty. The two keep one shape, so the swap moves
/// nothing; only the first line's words change. Never a working indicator for the agent itself.
export function SubagentEmptyRow({ row }: Pick<RowProps, "row">) {
  const t = useT();
  const loading = row.status === "loading";
  const title = loading ? t("subagents.loading.title") : t("subagents.empty.title");
  return (
    <section className="cv-subagent-empty" aria-label={title} aria-busy={loading || undefined}>
      <h3>{title}</h3>
      <p>{t("subagents.empty.detail")}</p>
    </section>
  );
}
