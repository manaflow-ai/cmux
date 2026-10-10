import React, { forwardRef, useState } from "react";
import { createPortal } from "react-dom";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import { SummarySection } from "./SummarySection";
import type { SessionSummary } from "./sessionSummary";
import { sanitizeSections, type SummaryRow, type SummarySectionInput } from "./summaryModel";

const ICONS = {
  file: "file.text",
  folder: "folder",
  link: "link.web",
  task: "task.status.started",
  warning: "status.warning",
  source: "search.files",
  change: "diff.file",
  agent: "agent.session",
} as const;
const FOLDED = 5;

export type PinnedSummaryProps = {
  summary: SessionSummary;
  sections?: readonly SummarySectionInput[];
  cwd?: string;
  projectName?: string;
  mode: "wide" | "narrow";
  onClose: () => void;
  onOpenChanges?: () => void;
  onRefresh?: () => void;
};

function ExternalRow({ row, cwd }: { row: SummaryRow; cwd: string }) {
  const t = useT();
  const [confirm, setConfirm] = useState(false);
  const local = Boolean(
    row.href?.startsWith("/") && row.href && (row.href === cwd || row.href.startsWith(`${cwd.replace(/\/$/, "")}/`)),
  );
  const icon = row.icon && ICONS[row.icon] ? ICONS[row.icon] : "agent.session";
  const body = (
    <>
      <Icon name={icon} size={12} row />
      <span className="acpmux-summary-text" title={row.title}>
        {row.title}
      </span>
      {row.badge && <span className="acpmux-summary-meta">{row.badge}</span>}
    </>
  );
  if (!row.href || local || row.provenance !== "agent")
    return row.href ? (
      <a
        className="acpmux-summary-row acpmux-summary-link"
        href={row.href}
        data-summary-path={local ? row.href : undefined}
      >
        {body}
      </a>
    ) : (
      <span className="acpmux-summary-row">{body}</span>
    );
  if (!confirm)
    return (
      <button type="button" className="acpmux-summary-row acpmux-summary-link" onClick={() => setConfirm(true)}>
        {body}
      </button>
    );
  return (
    <span className="acpmux-summary-row acpmux-summary-confirm">
      <Icon name="status.warning" size={12} row />
      <span className="acpmux-summary-text">{t("summary.agentLinkConfirm")}</span>
      <a href={row.href} data-confirm="true">
        {t("summary.openLink")}
      </a>
    </span>
  );
}

export const PinnedSummary = forwardRef<HTMLElement, PinnedSummaryProps>(function PinnedSummary(
  { summary, sections = [], cwd = "/", projectName, mode, onClose, onOpenChanges, onRefresh },
  ref,
) {
  const t = useT();
  const sectionInputs = sanitizeSections(sections, cwd);
  const builtins: SummarySectionInput[] = [
    {
      id: "changes",
      title: t("summary.changes"),
      provider: "builtin",
      rows: summary.outputs.map((file) => ({
        title: file.displayPath,
        subtitle: file.path,
        icon: file.created ? "file" : "change",
        badge: `+${file.additions} -${file.deletions}`,
        provenance: "builtin" as const,
        href: file.path,
      })),
    },
    {
      id: "plan",
      title: t("summary.plan"),
      provider: "builtin",
      rows: (summary.plans ?? []).map((plan) => ({
        title: plan.text,
        icon: "task" as const,
        provenance: "builtin" as const,
      })),
    },
    {
      id: "subagents",
      title: t("summary.subagents"),
      provider: "builtin",
      rows: summary.subagents.map((agent) => ({
        title: agent.title,
        icon: "agent" as const,
        badge: agent.state,
        provenance: "builtin" as const,
      })),
    },
    {
      id: "sources",
      title: t("summary.sources"),
      provider: "builtin",
      rows: summary.sources.map((source) => ({
        title: source.label,
        href: source.url,
        icon: "source" as const,
        provenance: "builtin" as const,
      })),
    },
    {
      id: "pullRequests",
      title: t("summary.pullRequests"),
      provider: "builtin",
      rows: summary.pullRequests.map((pr) => ({
        title: pr.title ?? `${pr.repo}#${pr.number}`,
        subtitle: pr.state,
        href: pr.url,
        icon: "change" as const,
        badge: `#${pr.number}`,
        provenance: "builtin" as const,
      })),
    },
    {
      id: "scheduled",
      title: t("summary.scheduled"),
      provider: "builtin",
      rows: summary.scheduled.map((wakeup) => ({
        title: wakeup.text,
        subtitle: wakeup.cron,
        icon: "task" as const,
        provenance: "builtin" as const,
      })),
    },
  ];
  const all = [...builtins, ...sectionInputs];
  const content = (
    <section
      ref={ref}
      className="acpmux-pinned-summary acpmux-summary-panel"
      data-summary-mode={mode}
      aria-label={t("summary.open")}
      role="region"
      tabIndex={-1}
      onKeyDown={(event) => {
        if (event.key === "Escape") {
          event.preventDefault();
          onClose();
        }
      }}
    >
      <header className="acpmux-pinned-summary-header">
        <strong className="acpmux-summary-text">{projectName || t("summary.project")}</strong>
        <button
          type="button"
          className="acpmux-pinned-summary-action"
          aria-label={t("summary.close")}
          onClick={onClose}
        >
          ×
        </button>
      </header>
      <div className="acpmux-pinned-summary-body">
        {all.map((section) =>
          section.rows.length === 0 ? null : (
            <div key={section.id} data-section-id={section.id}>
              <SummarySection
                title={section.title}
                items={section.rows.slice(0, 50)}
                row={(row) => (
                  <li key={`${section.id}-${row.title}`} data-provenance={row.provenance}>
                    <ExternalRow row={row} cwd={cwd} />
                  </li>
                )}
              />
            </div>
          ),
        )}
        {all.every((section) => section.rows.length === 0) && (
          <p className="acpmux-summary-none">{t("summary.none")}</p>
        )}
      </div>
      <footer className="acpmux-pinned-summary-footer">
        {onOpenChanges && (
          <button type="button" onClick={onOpenChanges}>
            {t("summary.changesView")}
          </button>
        )}
        {onRefresh && (
          <button type="button" onClick={onRefresh}>
            {t("summary.refresh")}
          </button>
        )}
        {sectionInputs.some((section) => section.rows.length > FOLDED) && (
          <span className="acpmux-summary-meta">{t("summary.viewAll", { n: 50 })}</span>
        )}
      </footer>
    </section>
  );
  const slot = document.querySelector<HTMLElement>(".acpmux-summary-slot");
  return slot ? createPortal(content, slot) : content;
});

PinnedSummary.displayName = "PinnedSummary";
