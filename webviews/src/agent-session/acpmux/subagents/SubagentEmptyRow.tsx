import { useT } from "../i18n";
import "./SubagentEmptyRow.css";

/// A known child with no recorded content. This is not a fetch or an agent working indicator.
export function SubagentEmptyRow() {
  const t = useT();
  return (
    <section className="cv-subagent-empty" aria-label={t("subagents.empty.title")}>
      <h3>{t("subagents.empty.title")}</h3>
      <p>{t("subagents.empty.detail")}</p>
    </section>
  );
}
