import "./harnessStatus.css";
import { useEffect, useRef, useState } from "react";
import { copyTextResult } from "./conversation/clipboard";
import { translate, type Translate, usePaneLanguage, useT } from "./i18n";
import type { AcpmuxRow, AcpmuxSnapshot } from "./model";
import { useEscapeToDismiss } from "./paneSurface";
import { usageLimitsLabel } from "./usageLimits";

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

type StatusField = readonly [label: string, value: string];

function display(value: unknown, t: Translate): string {
  return text(value) ?? t("status.notReported");
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
  const locale = usePaneLanguage();
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
  const auth = authSourceLabel(summary, t);
  const settings = source.settingsSources ?? summary.settingsSources;
  const usageLimits =
    usageLimitsLabel(source.usageLimits, t, locale) ??
    usageLimitsLabel(summary.usageLimits, t, locale) ??
    t("status.notReported");
  const fields: readonly StatusField[] = [
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
    <section className="acpmux-harness-status" aria-label={t("status.label")}>
      <div className="acpmux-harness-status__head">
        <div>
          <div className="acpmux-harness-status__eyebrow">{summary.harness ?? t("picker.harness")}</div>
          <h2>{t("status.title")}</h2>
        </div>
        <button
          type="button"
          className="acpmux-harness-status__copy-all"
          aria-label={copiedAll ? t("turn.copied") : t("status.copyAll")}
          onClick={() => void copyAll()}
        >
          <span aria-hidden={copiedAll}>{t("status.copyAll")}</span>
          <span aria-hidden={!copiedAll}>{t("turn.copied")}</span>
        </button>
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
