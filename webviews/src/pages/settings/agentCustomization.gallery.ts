// l10n-allow-file: gallery fixtures (sample paths and commands), not shipped UI.
// Settings > Agents > Claude Code & Codex (AgentCustomizationCard, labs.agentCustomization on in
// every variant: off, the card draws nothing). Its Hooks section: every Claude Code and Codex hook
// by agent and event, with its matcher, command and whether it runs.
import { settingsPageEntry, type PageFixtureStep, type SettingsPageVariant } from "../../gallery/format";
import { AGENT_CUSTOMIZATION_LAB } from "./components/AgentCustomizationCard";

const HOOKS = '[data-card="agentCustomization"] [data-agent-customization-section="hooks"]';
// Focusing the section's first control brings it into view.
const hooksShown: PageFixtureStep[] = [
  { selector: `${HOOKS} [data-agent-hook]`, action: "wait" },
  { selector: `${HOOKS} [data-hook-filter]`, action: "focus" },
];
const hook = (id: string) => `${HOOKS} [data-agent-hook="${id}"]`;
const variant = (note: string, steps: PageFixtureStep[] = hooksShown): SettingsPageVariant => ({
  section: "agents",
  focus: "card.agentCustomization",
  options: { values: { [AGENT_CUSTOMIZATION_LAB]: true } },
  steps,
  note,
});

export default settingsPageEntry({
  id: "pages.settings-agent-customization",
  title: "Settings Claude Code & Codex",
  area: "Settings",
  height: 900,
  covers: [
    "pages/settings/components/AgentCustomizationCard.tsx#AgentCustomizationCard",
    "pages/settings/components/AgentHooksSection.tsx#AgentHooksSection",
  ],
  anchors: [{ selector: '[data-card="agentCustomization"]' }],
  variants: {
    hooks: variant(
      "Hooks: every Claude Code and Codex hook by agent and event with its matcher and command; one turned off, cmux's own read-only, a Codex hook not yet approved.",
    ),
    "hooks-codex": variant("Hooks filtered to Codex: its two hooks only.", [
      ...hooksShown,
      { selector: `${HOOKS} [data-hook-filter="codex"]`, action: "click" },
    ]),
    "hooks-turned-off": variant("The guard hook just turned off: Off, with Turn On in place of Turn Off.", [
      ...hooksShown,
      { selector: `${hook("claude-0a1b2c3d4e")} [data-hook-action="disable"]`, action: "click" },
      { selector: `${hook("claude-0a1b2c3d4e")}[data-hook-enabled="false"]`, action: "wait" },
    ]),
    "hooks-confirm-remove": variant("Remove on a Codex hook asks once more before it deletes anything.", [
      ...hooksShown,
      { selector: `${hook("codex-4a1b2c3d4e")} [data-hook-action="remove"]`, action: "click" },
      { selector: `${hook("codex-4a1b2c3d4e")} [data-hook-action="confirmRemove"]`, action: "wait" },
    ]),
  },
});
