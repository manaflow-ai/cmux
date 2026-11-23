import { translate, type Translate } from "./i18n";
import type { AcpmuxSnapshot } from "./model";

export type Summary = NonNullable<AcpmuxSnapshot["summary"]>;

export function text(value: unknown): string | undefined {
  return typeof value === "string" && value.trim() ? value.trim() : undefined;
}

export function info(summary: Summary): Record<string, unknown> {
  return summary.agentInfo && typeof summary.agentInfo === "object" && !Array.isArray(summary.agentInfo)
    ? summary.agentInfo
    : {};
}

/** Only the explicit label is displayable; arbitrary metadata keys may contain credentials. */
export function authSourceLabel(summary: Summary, t: Translate = translate): string {
  const source = info(summary);
  return text(source.authSource) ?? text(summary.authSource) ?? t("status.notReported");
}

export type StatusField = readonly [label: string, value: string];

/** The same plain text that Copy all puts on the clipboard. */
export function statusCardCopyText(fields: readonly StatusField[]): string {
  return fields.map(([label, value]) => `${label}: ${value}`).join("\n");
}
