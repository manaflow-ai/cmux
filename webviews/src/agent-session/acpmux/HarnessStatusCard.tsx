import "./harnessStatus.css";
import { useEffect, useRef, useState } from "react";
import { copyTextResult } from "./conversation/clipboard";
import { useT } from "./i18n";
import type { AcpmuxRow, AcpmuxSnapshot } from "./model";
import { useEscapeToDismiss } from "./paneSurface";

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

type StatusField = readonly [label: string, value: string];

function display(value: unknown): string {
  return text(value) ?? "Not reported";
}

/** The same plain text that Copy all puts on the clipboard. */
export function statusCardCopyText(fields: readonly StatusField[]): string {
  return fields.map(([label, value]) => `${label}: ${value}`).join("\n");
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
  // This card can be open while the composer owns focus. Capture an otherwise-unclaimed Escape
  // here; open menus and popovers remain first in line (paneSurface.ts).
  useEscapeToDismiss(true, onDismiss, { capture: true });
  const [copiedField, setCopiedField] = useState<string>();
  const copiedTimer = useRef<number | undefined>(undefined);
  const [copiedAll, setCopiedAll] = useState(false);
  const allTimer = useRef<number | undefined>(undefined);
  useEffect(() => () => window.clearTimeout(copiedTimer.current), []);
  useEffect(() => () => window.clearTimeout(allTimer.current), []);
  if (!summary) return null;
  const source = info(summary);
  const auth = authSourceLabel(summary);
  const settings = source.settingsSources ?? summary.settingsSources;
  const usageLimits = text(source.usageLimits) ?? text(summary.usageLimits) ?? "Not reported";
  const fields: readonly StatusField[] = [
    ["Version", version(rows, summary)],
    ["Session", display(summary.sessionId)],
    ["CWD", display(summary.cwd)],
    ["Host", display(summary.host ?? summary.peer)],
    ["Model", display(summary.model)],
    ["Effort", display(summary.effort)],
    ["Auth source", auth],
    ["Routing", routeLabel(summary)],
    ["Settings", listLabel(settings)],
    ["Context", usageLabel(summary)],
    ["Usage limits", usageLimits],
  ] as const;
  const copyField = async (label: string, value: string, target: HTMLElement) => {
    const selection = window.getSelection();
    if (
      selection &&
      !selection.isCollapsed &&
      selection.anchorNode &&
      target.contains(selection.anchorNode) &&
      selection.focusNode &&
      target.contains(selection.focusNode)
    ) {
      // A drag selection is the person's partial-copy gesture; don't replace it with the full
      // field just because the browser emits a click after the selection ends.
      return;
    }
    if (!(await copyTextResult(value))) return;
    window.clearTimeout(copiedTimer.current);
    setCopiedField(label);
    copiedTimer.current = window.setTimeout(() => setCopiedField(undefined), 1200);
  };
  const copyAll = async () => {
    if (!(await copyTextResult(statusCardCopyText(fields)))) return;
    window.clearTimeout(allTimer.current);
    setCopiedAll(true);
    allTimer.current = window.setTimeout(() => setCopiedAll(false), 1200);
  };
  return (
    <section className="acpmux-harness-status" aria-label="Harness status">
      <div className="acpmux-harness-status__head">
        <div>
          <div className="acpmux-harness-status__eyebrow">{summary.harness ?? "Harness"}</div>
          <h2>Session status</h2>
        </div>
        <button type="button" className="acpmux-harness-status__copy-all" onClick={() => void copyAll()}>
          {copiedAll ? t("turn.copied") : t("status.copyAll")}
        </button>
        <button type="button" className="acpmux-harness-status__close" onClick={onDismiss} aria-label="Close status">
          ×
        </button>
      </div>
      <dl className="acpmux-harness-status__grid">
        {fields.map(([label, value]) => (
          <div key={label} className="acpmux-harness-status__field">
            <dt>{label}</dt>
            <dd>
              <button
                type="button"
                className="acpmux-harness-status__value"
                data-copy-label={label}
                title={value}
                aria-label={`${t("turn.copy")} ${label}: ${value}`}
                onClick={(event) => void copyField(label, value, event.currentTarget)}
              >
                <span className="acpmux-harness-status__value-text">{value}</span>
                <span className="acpmux-harness-status__copy-feedback" aria-live="polite">
                  {copiedField === label ? t("turn.copied") : ""}
                </span>
              </button>
            </dd>
          </div>
        ))}
      </dl>
    </section>
  );
}
