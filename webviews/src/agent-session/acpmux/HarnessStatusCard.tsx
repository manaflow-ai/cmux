import "./harnessStatus.css";
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
export function authSourceLabel(summary: Summary): string {
  const source = info(summary);
  return text(source.authSource) ?? text(summary.authSource) ?? "Not reported";
}

function routeLabel(summary: Summary): string {
  const source = info(summary);
  const route = text(source.routeName) ?? text(source.route) ?? text(summary.route);
  if (route) return route;
  const base = text(source.baseUrl) ?? text(source.baseURL) ?? text(summary.baseUrl);
  if (!base) return "Not reported";
  try {
    return new URL(base).origin;
  } catch {
    return "Reported endpoint";
  }
}

function listLabel(value: unknown): string {
  if (!Array.isArray(value)) return "Not reported";
  const values = value.filter((item): item is string => typeof item === "string" && Boolean(item.trim()));
  return values.length ? values.join(", ") : "Not reported";
}

function version(rows: readonly AcpmuxRow[], summary: Summary): string {
  const source = info(summary);
  return (
    text(source.version) ??
    [...rows].reverse().find((row) => row.sessionStart?.version)?.sessionStart?.version ??
    "Not reported"
  );
}

function usageLabel(summary: Summary): string {
  const usage = summary.usage;
  if (!usage || usage.size <= 0 || usage.used < 0) return "Not reported";
  const percent = Math.round(Math.min(1, Math.max(0, usage.used / usage.size)) * 100);
  return `${percent}% (${usage.used.toLocaleString()} / ${usage.size.toLocaleString()} tokens)`;
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
  if (!summary) return null;
  const source = info(summary);
  const auth = authSourceLabel(summary);
  const settings = source.settingsSources ?? summary.settingsSources;
  const usageLimits = text(source.usageLimits) ?? text(summary.usageLimits) ?? "Not reported";
  const fields = [
    ["Version", version(rows, summary)],
    ["Session", summary.sessionId],
    ["CWD", summary.cwd ?? "Not reported"],
    ["Host", summary.host ?? summary.peer ?? "Not reported"],
    ["Model", summary.model ?? "Not reported"],
    ["Effort", summary.effort ?? "Not reported"],
    ["Auth source", auth],
    ["Routing", routeLabel(summary)],
    ["Settings", listLabel(settings)],
    ["Context", usageLabel(summary)],
    ["Usage limits", usageLimits],
  ] as const;
  return (
    <section className="acpmux-harness-status" aria-label="Harness status">
      <div className="acpmux-harness-status__head">
        <div>
          <div className="acpmux-harness-status__eyebrow">{summary.harness ?? "Harness"}</div>
          <h2>Session status</h2>
        </div>
        <button type="button" className="acpmux-harness-status__close" onClick={onDismiss} aria-label="Close status">
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
