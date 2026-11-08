// l10n-allow-file: gallery fixtures (sample skills, projects and plugins), not shipped UI.
// Settings > Skills (SkillsCard): every skill this Mac's harnesses load, grouped by harness and
// source, with switches, Open in Editor, Show in Finder and New Skill. The layouts it was picked from
// are settings.skills-layouts.
import { settingsPageEntry, type PageFixtureStep, type SettingsPageVariant } from "../../gallery/format";
import { mockManySkills } from "./mockProvider";

const shown: PageFixtureStep = { selector: '[data-card="skills"]', action: "wait" };
const variant = (patch: Partial<SettingsPageVariant> & { note: string }): SettingsPageVariant => ({
  section: "skills",
  steps: [shown],
  ...patch,
});

export default settingsPageEntry({
  id: "pages.settings-skills",
  title: "Settings Skills",
  area: "Settings",
  height: 720,
  covers: ["pages/settings/components/SkillsCard.tsx#SkillsCard"],
  anchors: [{ selector: '[data-card="skills"]' }],
  variants: {
    shipped: variant({
      note: "Both harnesses: Personal, a project, a plugin (its switch turns the whole plugin), Admin and System; a problem, an overridden and turned-off rows.",
    }),
    expanded: variant({
      steps: [shown, { selector: '[data-skill="claude:user:release-notes"] [data-skills-expand]', action: "click" }],
      note: "A row unfolds its file and full description in place, on the house settle curve.",
    }),
    "new-skill": variant({
      steps: [shown, { selector: '[data-skills-action="new"]', action: "click" }],
      note: "New Skill: harness, Personal or a listed project, a checked name and a description.",
    }),
    many: variant({
      skills: mockManySkills(),
      note: "60 skills: off-screen rows skip layout; search filters through one index.",
    }),
    empty: variant({
      skills: { available: true, home: "/Users/sam", projects: [], skills: [] },
      note: "No skills: one short line.",
    }),
    unavailable: variant({
      skills: { available: false },
      note: "This Mac's daemon is not connected: one short line instead of the list.",
    }),
  },
});
