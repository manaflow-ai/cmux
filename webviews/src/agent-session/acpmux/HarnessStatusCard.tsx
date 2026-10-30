import "./harnessStatus.css";
import { translate, type Translate, useT } from "./i18n";
import type { AcpmuxRow, AcpmuxSnapshot } from "./model";

type Summary = NonNullable<AcpmuxSnapshot["summary"]>;

function text(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

function info(summary: Summary): Record<string, unknown> {
  return summary.agentInfo && typeof summary.agentInfo === "object" && !Array.isArray(summary.agentInfo)
    ? summary.agentInfo
    : {};
}

/** Only the explicit label is displayable; arbitrary metadata keys may contain credentials. */
export function authSourceLabel(summary: Summary, t: Translate = translate): string {
  const source = info(summary);
  return text(source.authSource) ?? text(summary.authSource) ?? t("status.notReported");
}

function routeLabel(summary: Summary, t: Translate): string {
  const source = info(summary);
  const route = text(source.routeName) ?? text(source.route) ?? text(summary.route);
  if (route) return route;
  const base = text(source.baseUrl) ?? text(source.baseURL) ?? text(summary.baseUrl);
  if (!base) return t("status.notReported");
  try {
    return new URL(base).origin;
  } catch {
    return t("status.reportedEndpoint");
  }
}

function listLabel(value: unknown, t: Translate): string {
  if (!Array.isArray(value)) return t("status.notReported");
  const values = value.filter((item): item is string => typeof item === "string" && Boolean(item.trim()));
  return values.length ? values.join(", ") : t("status.notReported");
}

function version(rows: readonly AcpmuxRow[], summary: Summary, t: Translate): string {
  const source = info(summary);
  return (
    text(source.version) ??
    [...rows].reverse().find((row) => row.sessionStart?.version)?.sessionStart?.version ??
    t("status.notReported")
  );
}

function usageLabel(summary: Summary, t: Translate): string {
  const usage = summary.usage;
  if (!usage || usage.size <= 0 || usage.used < 0) return t("status.notReported");
  const percent = Math.round(Math.min(1, Math.max(0, usage.used / usage.size)) * 100);
  return t("status.usage", { percent, used: usage.used.toLocaleString(), size: usage.size.toLocaleString() });
}

function display(value: unknown, t: Translate): string {
  return text(value) ?? t("status.notReported");
}

/** The shared `/status` card. Values are normalized to labels and never render credential values. */
export function HarnessStatusCard({
  summary,
  rows,
  onDismiss,
}: {
  summary: AcpmuxSnapshot["summary"];
  rows: readonly AcpmuxRow[];
  onDismiss(): void;
}) {
  const t = useT();
  if (!summary) return null;
  const source = info(summary);
  const auth = authSourceLabel(summary, t);
  const settings = source.settingsSources ?? summary.settingsSources;
  const usageLimits = text(source.usageLimits) ?? text(summary.usageLimits) ?? t("status.notReported");
  const fields = [
    [t("status.field.version"), version(rows, summary, t)],
    [t("status.field.session"), display(summary.sessionId, t)],
    [t("status.field.cwd"), display(summary.cwd, t)],
    [t("status.field.host"), display(summary.host ?? summary.peer, t)],
    [t("status.field.model"), display(summary.model, t)],
    [t("status.field.effort"), display(summary.effort, t)],
    [t("status.field.authSource"), auth],
    [t("status.field.routing"), routeLabel(summary, t)],
    [t("status.field.settings"), listLabel(settings, t)],
    [t("status.field.context"), usageLabel(summary, t)],
    [t("status.field.usageLimits"), usageLimits],
  ] as const;
  return (
    <section className="acpmux-harness-status" aria-label={t("status.label")}>
      <div className="acpmux-harness-status__head">
        <div>
          <div className="acpmux-harness-status__eyebrow">{summary.harness ?? t("picker.harness")}</div>
          <h2>{t("status.title")}</h2>
        </div>
        <button
          type="button"
          className="acpmux-harness-status__close"
          onClick={onDismiss}
          aria-label={t("status.close")}
        >
          ×
        </button>
      </div>
      <dl className="acpmux-harness-status__grid">
        {fields.map(([label, value]) => (
          <div key={label} className="acpmux-harness-status__field">
            <dt>{label}</dt>
            <dd title={value}>{value}</dd>
          </div>
        ))}
      </dl>
    </section>
  );
}
