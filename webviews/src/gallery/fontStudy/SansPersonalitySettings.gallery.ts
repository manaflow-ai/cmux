// l10n-allow-file: gallery fixtures, not shipped UI.
// cmux Sans's personalities on Settings: Chat's Chat Text card, the Chat Interface Font row picked,
// with the page drawn in that font (`--font-ui` and the type steps' tracking, as the font study sets
// them). Leo, 2026-11-19: cmux Sans looks "a bit like generic school font ... It just doesn't have that
// like pizzazz"; he likes squat faces, and Folio's sans (Hanken Grotesk, the `hanken` variant) is
// the reference. The chat and sidebar in each font: font-study.sans-personality.
import { settingsPageEntry, type SettingsPageVariant } from "../format";
import { applyArmFont, SANS_PERSONALITIES, SANS_PERSONALITY_NAMES, sansPersonality } from "./sansPersonality";

const KEY = "agentPane.display.font.ui";

export default settingsPageEntry({
  id: "pages.settings-sans-personality",
  title: "Settings in cmux Sans personalities",
  area: "Settings",
  height: 760,
  covers: ["page:cmux.settings", "gallery/fontStudy/sansPersonality.ts"],
  keywords: ["font", "typeface", "typography", "cmux sans", "hanken", "squat", "candy", "open", "interface font"],
  variants: Object.fromEntries(
    SANS_PERSONALITY_NAMES.map((name): [string, SettingsPageVariant] => {
      const { value, note, pairing } = SANS_PERSONALITIES[name];
      return [
        name,
        {
          section: "chat",
          focus: KEY,
          options: value ? { values: { [KEY]: value } } : undefined,
          note,
          fontStudy: pairing,
        },
      ];
    }),
  ),
  experiment: {
    definition: sansPersonality,
    setup: applyArmFont,
    script: [
      {
        name: "search font",
        run: async (ctx) => {
          await ctx.click({ selector: "[data-settings-search]" });
          await ctx.type("font");
        },
      },
    ],
  },
});
