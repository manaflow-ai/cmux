import type { useT } from "../i18n";
import type { AgentHome } from "./carriedSectionModel";

/// The folded header's value: "2 waiting · 14 files", "Off" when nothing follows the person here.
export function carriedSummary(
  t: ReturnType<typeof useT>,
  home: AgentHome | undefined,
  failed: boolean,
): string | undefined {
  if (!home) return failed ? t("carried.failed") : undefined;
  if (!home.configured) return t("carried.off");
  const parts: string[] = [];
  if (home.proposals.length > 0) parts.push(t("summary.subagents.waiting", { n: home.proposals.length }));
  parts.push(t("carried.files", { n: home.carried.length }));
  return parts.join(" · ");
}
