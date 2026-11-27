// l10n-allow-file: gallery fixtures (sample looks and a refusal), not shipped UI.
// Settings > Appearance > Looks (LooksGalleryCard) on the real page and store: the catalog's tiles,
// each its golden sample, Install and its consent card, and the installed looks stacked top first.
// The route's `focus=card.looksGallery` scrolls the page to the card, so each capture shows it. The
// layouts it was picked from are settings.looks-gallery-layouts.
import { settingsPageEntry, type PageFixtureStep, type SettingsPageVariant } from "../../gallery/format";
import { mockStackedLooks } from "./mockLooks";

const shown: PageFixtureStep = { selector: '[data-card="looksGallery"]', action: "wait" };
const variant = (patch: Partial<SettingsPageVariant> & { note: string }): SettingsPageVariant => ({
  section: "appearance",
  focus: "card.looksGallery",
  steps: [shown],
  ...patch,
});

export default settingsPageEntry({
  id: "pages.settings-looks-gallery",
  title: "Settings Looks gallery",
  area: "Settings",
  height: 720,
  covers: ["pages/settings/components/LooksGalleryCard.tsx#LooksGalleryCard"],
  anchors: [{ selector: '[data-card="looksGallery"]' }],
  variants: {
    shipped: variant({ note: "The catalog's four looks, nothing installed: each tile its golden sample and Install." }),
    consent: variant({
      steps: [
        shown,
        { selector: '[data-look="manaflow-ai/newtab-cards-look"] [data-looks-action="install"]', action: "click" },
        { selector: "[data-looks-consent]", action: "wait" },
      ],
      note: "Install on New Tab Cards: its consent card lists what it changes, with Cancel focused.",
    }),
    stacked: variant({
      options: { looks: mockStackedLooks() },
      note: "Paper on over Studio off, and a setup from outside the gallery, stacked top first.",
    }),
    "no-preview": variant({
      options: { looksPreviewMissing: ["manaflow-ai/newtab-threads-look"] },
      note: "New Tab Threads' repo has no preview image: its tile says so in the same frame.",
    }),
    refused: variant({
      options: { looks: mockStackedLooks(), looksRefusal: "the network is offline" },
      steps: [shown, { selector: '[data-looks-layer="manaflow-ai/paper-look"] [role="switch"]', action: "click" }],
      note: "Turning Paper off when the CLI refuses: its words show under the gallery.",
    }),
  },
});
