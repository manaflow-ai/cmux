// l10n-allow-file: gallery fixtures (sample library entries and a refusal), not shipped UI.
// Settings > Personalization > Customization Library (CustomizeLibraryCard) on the real page and
// store: everything the person applied, top first, with its switch and order. The layouts it was
// picked from are settings.customize-library-layouts. With nothing applied the page draws no card
// (opt-in), so its empty state is only in that entry.
import { settingsPageEntry, type PageFixtureStep, type SettingsPageVariant } from "../../gallery/format";
import { mockLongLibrary } from "./mockLibrary";

const shown: PageFixtureStep = { selector: '[data-card="customizeLibrary"]', action: "wait" };
const variant = (patch: Partial<SettingsPageVariant> & { note: string }): SettingsPageVariant => ({
  section: "personalization",
  focus: "card.customizeLibrary",
  steps: [shown],
  ...patch,
});

export default settingsPageEntry({
  id: "pages.settings-customize-library",
  title: "Settings Customization Library",
  area: "Settings",
  height: 640,
  covers: ["pages/settings/components/CustomizeLibraryCard.tsx#CustomizeLibraryCard"],
  anchors: [{ selector: '[data-card="customizeLibrary"]' }],
  variants: {
    shipped: variant({
      note: "Five entries, one off; night and roomy both set the sidebar width, and roomy says night wins.",
    }),
    fifty: variant({ library: mockLongLibrary(50), note: "Fifty entries, every third one off." }),
    refused: variant({
      libraryRefusal:
        "a preview is open: apply or discard it first (`cmux customize apply` or `discard`), then change the library",
      steps: [shown, { selector: '[data-library-entry="night"] [role="switch"]', action: "click" }],
      note: "Turning night off while a preview is open: the CLI refuses, and its words show under the list.",
    }),
    remove: variant({
      steps: [shown, { selector: '[data-library-entry="paper"] [data-library-action="remove"]', action: "click" }],
      note: "Remove asks first, inline.",
    }),
  },
});
