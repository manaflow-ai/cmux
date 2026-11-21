// Settings > Agents > Claude Code & Codex (Labs: labs.agentCustomization, off by default). Leo,
// 2026-11-19: "Claude Code, Codex and Rex customization visible in cmux". The card is a shell: each
// part of the agents' own customization is its own section (Hooks here; others add theirs beside it).
// Off, it draws nothing, asks the app for nothing, and the page is as before.
import { useSettingsSelector } from "../context";
import { valueOf } from "../store";
import { t } from "../strings";
import { AgentHooksSection } from "./AgentHooksSection";

/** The Labs switch (schemas/settings/source/labs.json); off, the card draws nothing. */
export const AGENT_CUSTOMIZATION_LAB = "labs.agentCustomization";

export function AgentCustomizationCard() {
  const on = useSettingsSelector((state) => valueOf(state, AGENT_CUSTOMIZATION_LAB) === true);
  if (!on) return null;
  return (
    <section className="group" data-card="agentCustomization">
      <h3 className="group-title">{t("settingsWindow.agentCustomization.title")}</h3>
      <AgentHooksSection />
    </section>
  );
}
