// l10n-allow-file: gallery fixtures (entry titles), not shipped UI.
// The golden Settings page: Settings drawn under each look (looks.json), from the same inputs as the
// golden screen (golden.gallery.ts), so a look is pictured on Settings too. The stage's light or dark
// scheme picks the look's theme file, which themes the page (frame/main.ts) and is the host's current
// theme; the look's settings, composer look and theme file keys are the values Settings lists
// (frame/settingsPasswords.ts, golden/look.ts lookSettingsValues). One entry per section: Appearance,
// where a look's own rows are, and Chat, a long section with the chat's display rows
// (settingsAppearance.gallery.ts, settingsChat.gallery.ts).
// `bun run golden:looks --settings appearance,chat` captures them beside the golden screen.
import looks from "virtual:cmux-gallery/looks";
import type { SettingsPageVariant } from "../format";
import type { GOLDEN_SETTINGS_SECTIONS } from "./look";

const golden = (look: (typeof looks.looks)[number], section: string): SettingsPageVariant => ({
  note: `${look.title}: ${look.note} (${look.source})`,
  section,
  look,
  // Every bundled theme, so the look's named theme is one the picker lists.
  allThemes: true,
});

/** An entry's parts but its id and title, which each gallery file writes as literals (test/gallery-entry-path.test.ts). */
export const goldenSettings = (section: (typeof GOLDEN_SETTINGS_SECTIONS)[number]) => ({
  area: "Settings",
  height: 1100,
  covers: ["page:cmux.settings", "gallery/golden/look.ts"],
  keywords: ["look", "golden", "theme", "setup"],
  variants: Object.fromEntries(looks.looks.map((look) => [look.id, golden(look, section)])),
});
