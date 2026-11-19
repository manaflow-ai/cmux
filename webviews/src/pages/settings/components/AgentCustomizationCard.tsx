// Settings > Agents > Claude Code & Codex (Labs: labs.agentCustomization, off by default). Leo,
// 2026-11-19: "the customization with, like, getting, like, Claude Code, getting Codex". The card
// is a shell: each part of the agents' own customization is its own section (Settings here; MCP
// servers, skills and hooks add theirs beside it). Off, it draws nothing and the page is as before.
import { AGENT_CUSTOMIZATION_LAB } from "../agentConfig";
import { useSettingsSelector } from "../context";
import { valueOf } from "../store";
import { t } from "../strings";
import { AgentSettingsSection } from "./AgentSettingsSection";

export function AgentCustomizationCard() {
  const on = useSettingsSelector((state) => valueOf(state, AGENT_CUSTOMIZATION_LAB) === true);
  if (!on) return null;
  return (
    <section className="group" data-card="agentCustomization">
      <h3 className="group-title">{t("settingsWindow.agentConfig.title")}</h3>
      <div className="row-help">{t("settingsWindow.agentConfig.help")}</div>
      <AgentSettingsSection />
    </section>
  );
}
