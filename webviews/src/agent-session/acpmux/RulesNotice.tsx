import { useId, useState } from "react";
import { useT } from "./i18n";
import { useNoticeTurn } from "./noticeSlotModel";
import { useScrollEdges } from "../../ui/scrollEdges";
import { type ForumRule } from "./rulesNoticeModel";
/// The forum's current rules, pinned above the composer: one line with the newest rule, and
/// Show All for the Rules view, every rule with its author and how many agents acked it.
/// Nothing while there are none.
export function RulesNotice({ rules }: { rules: ForumRule[] }) {
  const t = useT();
  const [open, setOpen] = useState(false);
  const listId = useId();
  const listEdges = useScrollEdges();
  // Standing information in the one notice slot above the composer: it shows for as long as
  // rules exist, so every other notice (an error, a running step, a hint, an update the person
  // started) draws first and the rules come back once it clears.
  const { shown } = useNoticeTurn("rules", "info", rules.length > 0);
  if (!shown || rules.length === 0) return null;
  const newest = rules.reduce((a, b) => (b.created > a.created ? b : a));
  const from = (rule: ForumRule) =>
    rule.author.kind === "person"
      ? t("rules.fromPerson", { name: rule.author.account })
      : t("rules.fromAgent", { name: rule.author.name });
  return (
    <section className="acpmux-host-error acpmux-harness-notice acpmux-rules-notice" aria-label={t("rules.title")}>
      <div className="acpmux-host-error-card" data-rules-open={open ? "true" : "false"}>
        <p className="acpmux-rules-head">
          <span className="acpmux-rules-title">{t("rules.title")}</span>
          <span className="acpmux-rules-count">{rules.length}</span>
          <button
            type="button"
            data-notice-action="rules"
            aria-expanded={open}
            aria-controls={listId}
            onClick={() => setOpen(!open)}
          >
            {open ? t("rules.hide") : t("rules.showAll")}
          </button>
        </p>
        {open ? (
          <ul ref={listEdges} className="acpmux-rules-list ui-scroll-edge-fade" id={listId}>
            {rules.map((rule) => (
              <li key={rule.id} data-rule-key={rule.key}>
                <p className="acpmux-host-error-message">
                  <span className="acpmux-rules-key">{rule.key}</span> {rule.body}
                </p>
                <p className="acpmux-host-error-hint">
                  {from(rule)} · {t("rules.acks", { count: rule.acks.length })}
                </p>
              </li>
            ))}
          </ul>
        ) : (
          <p className="acpmux-host-error-message acpmux-rules-newest" title={newest.body}>
            <span className="acpmux-rules-key">{newest.key}</span> {newest.body}
          </p>
        )}
      </div>
    </section>
  );
}
