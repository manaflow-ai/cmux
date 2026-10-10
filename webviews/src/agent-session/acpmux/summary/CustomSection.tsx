import React, { useState } from "react";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { rowIconSize } from "../icons/iconSize";
import type { SummaryCustomSection, SummaryRow } from "./summaryRows";
import { SummarySection } from "./SummarySection";

const ROW_ICON = rowIconSize(12);
const STATE_DOT: Record<NonNullable<SummaryRow["state"]>, string> = {
  ok: "bg-[var(--agent-success,var(--acpmux-add,#3fb950))]",
  warn: "bg-[var(--agent-warning,var(--agent-accent))]",
  error: "bg-[var(--agent-danger)]",
  running: "bg-[var(--agent-accent)]",
};

/// A custom section's text (title, subtitle, badge, state dot). React escapes every string, so a
/// row that holds HTML shows it as text.
function RowText({ row }: { row: SummaryRow }) {
  return (
    <>
      {row.state && <span aria-hidden="true" className={`size-1.5 flex-none rounded-full ${STATE_DOT[row.state]}`} />}
      <span className="acpmux-summary-text">
        {row.title}
        {row.subtitle && <span className="ml-1.5 text-detail text-muted">{row.subtitle}</span>}
      </span>
      {row.badge && <span className="acpmux-summary-meta">{row.badge}</span>}
    </>
  );
}

/// One custom section (PINNED-SUMMARY S1): the user's, a provider's or the chat agent's rows.
/// A path opens like an output (`onOpenOutput`); a URL opens as a link, except a URL the agent
/// wrote, which first shows "Open <host>?" under its row. A failed provider shows its reason.
export function CustomSection({
  section,
  onOpenOutput,
  onFollow,
}: {
  section: SummaryCustomSection;
  onOpenOutput?: (path: string) => void;
  onFollow?: () => void;
}) {
  const t = useT();
  const [asking, setAsking] = useState<string | undefined>();
  const title = section.source === "agent" ? `${section.title} · ${t("summary.fromAgent")}` : section.title;
  if (section.error)
    return (
      <SummarySection
        id={section.id}
        title={title}
        fixed
        items={[section.error]}
        row={(reason) => (
          <li key="error" className="acpmux-summary-row text-muted" title={reason}>
            <Icon name="task.status.canceled" size={ROW_ICON} row />
            <span className="acpmux-summary-text">{t("summary.providerFailed", { reason })}</span>
          </li>
        )}
      />
    );
  return (
    <SummarySection
      id={section.id}
      title={title}
      fixed
      items={section.rows}
      row={(row) => {
        const link = row.link;
        if (link?.kind === "path")
          return (
            <li key={row.key}>
              <button
                type="button"
                className="acpmux-summary-row acpmux-summary-link"
                title={link.path}
                data-summary-path={link.path}
                disabled={!onOpenOutput}
                onClick={() => onOpenOutput?.(link.path)}
              >
                <RowText row={row} />
              </button>
            </li>
          );
        if (link?.kind === "url" && !link.confirm)
          return (
            <li key={row.key}>
              <a
                className="acpmux-summary-row acpmux-summary-link"
                href={link.url}
                title={link.url}
                data-summary-url={link.url}
                onClick={onFollow}
              >
                <RowText row={row} />
              </a>
            </li>
          );
        if (link?.kind === "url")
          return (
            <li key={row.key}>
              <button
                type="button"
                className="acpmux-summary-row acpmux-summary-link"
                title={link.url}
                data-summary-url={link.url}
                aria-expanded={asking === row.key}
                onClick={() => setAsking(asking === row.key ? undefined : row.key)}
              >
                <RowText row={row} />
                <Icon name="link.external" size={ROW_ICON} row />
              </button>
              {asking === row.key && (
                <div
                  data-summary-confirm
                  className="mx-2 mb-1 flex items-center gap-2 rounded-lg border border-edge px-2 py-1.5 text-detail text-muted"
                >
                  <span className="min-w-0 flex-1 truncate">{t("summary.openHost", { host: link.host })}</span>
                  <button
                    type="button"
                    className="h-6 cursor-default rounded-md border-0 bg-transparent px-2 font-[inherit] text-detail text-muted hover:bg-hover hover:text-fg"
                    onClick={() => setAsking(undefined)}
                  >
                    {t("summary.cancel")}
                  </button>
                  <a
                    href={link.url}
                    className="flex h-6 items-center rounded-md bg-hover px-2 text-detail text-fg no-underline"
                    onClick={() => {
                      setAsking(undefined);
                      onFollow?.();
                    }}
                  >
                    {t("summary.openConfirm")}
                  </a>
                </div>
              )}
            </li>
          );
        return (
          <li key={row.key} className="acpmux-summary-row">
            <RowText row={row} />
          </li>
        );
      }}
    />
  );
}
