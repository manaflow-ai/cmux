import type { StringKey } from "../i18n";
import type { NoticeSeverity } from "./agentNotice";

export const SEVERITY_LABEL: Record<NoticeSeverity, StringKey> = {
  fire: "notice.severity.fire",
  warn: "notice.severity.warn",
  info: "notice.severity.info",
};
