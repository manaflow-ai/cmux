// l10n-allow-file: gallery fixtures (sample paths and values), not shipped UI.
// Settings > Agents > Claude Code & Codex (AgentCustomizationCard, labs.agentCustomization on in
// every variant: off, the card draws nothing). Each agent's curated settings with the scope each
// comes from, the files with Open File, Codex's profile, and All Settings with a masked key.
import { settingsPageEntry, type PageFixtureStep, type SettingsPageVariant } from "../../gallery/format";
import { AGENT_CUSTOMIZATION_LAB } from "./agentConfig";

const shown: PageFixtureStep = { selector: '[data-card="agentCustomization"] [data-agent-count]', action: "wait" };
const variant = (note: string, steps: PageFixtureStep[] = [shown]): SettingsPageVariant => ({
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
    "pages/settings/components/AgentSettingsSection.tsx#AgentSettingsSection",
  ],
  anchors: [{ selector: '[data-card="agentCustomization"]' }],
  variants: {
    shipped: variant(
      "Claude Code's model from the project file over the user's, a local permission mode and an unset key; Codex's user settings, a missing project file and the fast profile.",
    ),
    "all-settings": variant(
      "All Settings open for Claude Code: every key, its scope, the masked API key and the override line.",
      [
        shown,
        { selector: '[data-agent-config="claude"] [data-agent-action="all"]', action: "click" },
        { selector: '[data-agent-config="claude"] [data-agent-entries]', action: "wait" },
      ],
    ),
    edited: variant("Codex's reasoning effort picked as low: the row shows the new value in User.", [
      shown,
      {
        selector: '[data-agent-config="codex"] [data-agent-setting="model_reasoning_effort"] select[data-agent-value]',
        action: "change",
        value: "low",
      },
    ]),
  },
});
