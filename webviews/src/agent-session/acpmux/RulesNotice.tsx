import { useId, useState } from "react";
import { useT } from "./i18n";
import { useNoticeTurn } from "./NoticeSlot";

/// One current rule of this Mac's acpmux forum (`_acpmux/forum/rules`, hq#2570): the newest
/// announcement of its key. A person's rule is an instruction to every agent; an agent's is
/// information.
export type ForumRule = {
  id: string;
  key: string;
  body: string;
  author: { kind: "person"; account: string } | { kind: "agent"; sessionId: string; name: string };
  created: number;
  acks: { sessionId: string; at: number }[];
};

/// The rules in a `_acpmux/forum/rules` reply; malformed rows are left out.
export function forumRules(reply: unknown): ForumRule[] {
  const rows = (reply as { rules?: unknown } | null)?.rules;
  if (!Array.isArray(rows)) return [];
  return rows.flatMap((row): ForumRule[] => {
    if (!row || typeof row !== "object") return [];
    const r = row as Record<string, unknown>;
    const author = r.author as Record<string, unknown> | null | undefined;
    if (
      typeof r.id !== "string" ||
      typeof r.key !== "string" ||
      typeof r.body !== "string" ||
      !author ||
      typeof author !== "object"
    )
      return [];
    const who =
      author.kind === "person" && typeof author.account === "string"
        ? { kind: "person" as const, account: author.account }
        : author.kind === "agent" && typeof author.name === "string"
          ? { kind: "agent" as const, sessionId: String(author.sessionId ?? ""), name: author.name }
          : undefined;
    if (!who) return [];
    const acks = (Array.isArray(r.acks) ? r.acks : []).flatMap((ack): ForumRule["acks"] => {
      const a = ack as Record<string, unknown> | null;
      return a && typeof a.sessionId === "string" ? [{ sessionId: a.sessionId, at: Number(a.at ?? 0) }] : [];
    });
    return [{ id: r.id, key: r.key, body: r.body, author: who, created: Number(r.created ?? 0), acks }];
  });
}

/// The forum's current rules, pinned above the composer: one line with the newest rule, and
/// Show All for the Rules view, every rule with its author and how many agents acked it.
/// Nothing while there are none.
export function RulesNotice({ rules }: { rules: ForumRule[] }) {
  const t = useT();
  const [open, setOpen] = useState(false);
  const listId = useId();
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
          <ul className="acpmux-rules-list" id={listId}>
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
