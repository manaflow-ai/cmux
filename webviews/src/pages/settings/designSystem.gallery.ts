// l10n-allow-file: gallery fixtures (the CLI's English notes and messages), not shipped UI.
// Settings > Design System (under More) (DesignSystemCard, RFD 0009 slice 8): the design system
// extension views are drawn with, resolved in Rust over cmux, the active theme file's `design` key
// and design.json beside the settings file, and drawn by the SDK's own DesignSystemView (the scene
// `cmux --json ext design --show --scene` answers; fixtures/design-system-page.json).
import { settingsPageEntry, type PageFixtureStep, type SettingsPageVariant } from "../../gallery/format";
import { mockDesignSystem } from "./mockDesignSystem";

const shown: PageFixtureStep = { selector: '[data-card="designSystem"]', action: "wait" };
const variant = (patch: Partial<SettingsPageVariant> & { note: string }): SettingsPageVariant => ({
  section: "designSystem",
  steps: [shown],
  ...patch,
});

export default settingsPageEntry({
  id: "pages.settings-design-system",
  title: "Settings Design System",
  area: "Settings",
  height: 2000,
  covers: ["pages/settings/components/DesignSystemCard.tsx#DesignSystemCard"],
  anchors: [{ selector: '[data-card="designSystem"]' }],
  variants: {
    cmux: variant({
      designSystem: mockDesignSystem("cmux"),
      note: "No design.json: cmux's own system, its seven type roles, the spacing scale, the color roles, the components and the limits.",
    }),
    changed: variant({
      designSystem: mockDesignSystem("changed"),
      note: "Built on design.json, with a base recorded: Changed in cmux lists the numeral (you get the new one) and the scale (yours holds), and each row carries its mark.",
    }),
    unreadable: variant({
      designSystem: mockDesignSystem("unreadable"),
      note: "The theme file's design layer did not read: the system is built from the rest, and the layer's problem is listed under the viewer.",
    }),
  },
});
