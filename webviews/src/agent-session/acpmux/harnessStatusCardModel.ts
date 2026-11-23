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

type Provenance = NonNullable<Summary["provenance"]>;

function named(label: string, name: unknown, t: Translate): string {
  const value = text(name);
  return value ? t("status.provenance.named", { label, name: value }) : label;
}

function accountLabel(p: Provenance, t: Translate): string {
  switch (p.account) {
    case "default":
      return t("status.account.default");
    case "profile":
      return named(t("status.account.profile"), p.accountName, t);
    case "environment":
      return named(t("status.account.environment"), p.accountName, t);
    case "unresolved":
      return t("status.account.unresolved");
    default:
      return t("status.notReported");
  }
}

function credentialLabel(p: Provenance, t: Translate): string {
  switch (p.credential) {
    case "launcher":
      return t("status.credential.launcher");
    case "route":
      return t("status.credential.route");
    case "profile":
      return t("status.credential.profile");
    case "environment":
      return t("status.credential.environment");
    case "agentLogin":
      return t("status.credential.agentLogin");
    default:
      return t("status.notReported");
  }
}

function configLabel(p: Provenance, t: Translate): string {
  switch (p.config) {
    case "managed":
      return named(t("status.config.managed"), p.configName, t);
    case "profileFile":
      return named(t("status.config.profileFile"), p.configName, t);
    case "cmuxJson":
      return t("status.config.cmuxJson");
    case "configFile":
      return t("status.config.configFile");
    case "discovered":
      return t("status.config.discovered");
    case "fixture":
      return t("status.config.fixture");
    default:
      return t("status.notReported");
  }
}

function eligibilityLabel(p: Provenance, t: Translate): string {
  switch (p.eligibility) {
    case "eligible":
      return t("status.eligibility.eligible");
    case "notInstalled":
      return t("status.eligibility.notInstalled");
    case "signInNeeded":
      return t("status.eligibility.signInNeeded");
    case "expired":
      return t("status.eligibility.expired");
    case "notEntitled":
      return t("status.eligibility.notEntitled");
    case "unknown":
      return t("status.eligibility.unknown");
    default:
      return t("status.notReported");
  }
}

/**
 * The card's provenance rows: the account home, the credential's owner, the config and
 * eligibility, as acpmux computed them. Only acpmux's fixed words become labels; an unknown word
 * reads "Not reported". None when acpmux sent no provenance (an older daemon).
 */
export function provenanceFields(summary: Summary, t: Translate = translate): StatusField[] {
  const p = summary.provenance;
  if (!p || typeof p !== "object") return [];
  return [
    [t("status.field.account"), accountLabel(p, t)],
    [t("status.field.credential"), credentialLabel(p, t)],
    [t("status.field.config"), configLabel(p, t)],
    [t("status.field.eligibility"), eligibilityLabel(p, t)],
  ];
}
