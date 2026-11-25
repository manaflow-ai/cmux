// l10n-allow-file: gallery fixtures (sample findings in the CLI's words), not shipped UI.
// Settings > Personalization > Customization Problems (CustomizeDoctorCard) on the real page and
// store, above the Customization Library, and its one-line notice in each treatment
// (design/customize-doctor.md): `inline` (shipped), the count and line in the card's header; `banner`,
// a warning Notice across the top of the column. The sidebar draws none (Lawrence 2026-11-23). The route's `focus=card.customizeDoctor` scrolls the page to the card. With
// nothing found the page draws no card and no notice (the `empty` variant waits for the library).
import { settingsPageEntry, type PageFixtureStep, type SettingsPageVariant } from "../../gallery/format";
import { mockAllDoctor, mockDismissedDoctor, mockDoctor, mockEmptyDoctor, mockOverrideDoctor } from "./mockDoctor";

const shown: PageFixtureStep = { selector: '[data-card="customizeDoctor"]', action: "wait" };
const variant = (patch: Partial<SettingsPageVariant> & { note: string }): SettingsPageVariant => ({
  section: "personalization",
  focus: "card.customizeDoctor",
  doctor: mockDoctor(),
  steps: [shown],
  ...patch,
});

export default settingsPageEntry({
  id: "pages.settings-customize-doctor",
  title: "Settings Customization Problems",
  area: "Settings",
  height: 640,
  covers: [
    "pages/settings/components/CustomizeDoctorCard.tsx#CustomizeDoctorCard",
    "pages/settings/components/CustomizeDoctorCard.tsx#DoctorNotice",
  ],
  anchors: [{ selector: '[data-card="customizeDoctor"]' }],
  variants: {
    "stale-layer-broken-file": variant({
      note: "pr-45206 is still on, themes/night.json does not load (Restore last good) and the split divider opacity is 0 (Leo's case, Follow default): the card above the library with Recover…, its count and line in the card's header.",
    }),
    "recover-confirm": variant({
      steps: [shown, { selector: '[data-card="customizeDoctor"] [data-doctor-action="recover"]', action: "click" }],
      note: "Recover… asks first, showing the CLI's plan (what goes off, which generation comes back, what is kept).",
    }),
    "restore-confirm": variant({
      steps: [
        shown,
        { selector: '[data-doctor-finding="broken:themes/night.json"] [data-doctor-fix="restore"]', action: "click" },
      ],
      note: "Restore last good asks first and says the broken text is kept.",
    }),
    override: variant({
      doctor: mockOverrideDoctor(),
      note: "A file outside the usual settings that still changes cmux: info, Open only, and no Recover….",
    }),
    empty: variant({
      doctor: mockEmptyDoctor(),
      steps: [{ selector: '[data-card="customizeLibrary"]', action: "wait" }],
      note: "Nothing found: no card and no notice (the start and the end state).",
    }),
    "all-kinds": variant({
      doctor: mockAllDoctor(),
      note: "One finding of each of the eleven kinds (override and not-default among them), warnings first.",
    }),
    dismissed: variant({
      doctor: mockDismissedDoctor(),
      note: "The broken theme dismissed: it draws muted at the end, and the line counts the other two.",
    }),
    "remove-confirm": variant({
      doctor: mockAllDoctor(),
      steps: [
        shown,
        {
          selector: '[data-doctor-finding="leftover:layers/branch-sidebar-tint"] [data-doctor-fix="remove"]',
          action: "click",
        },
      ],
      note: "Remove asks first, inline under its finding, with Cancel focused; it says a copy is kept.",
    }),
    "treatment-banner": variant({
      section: "general",
      focus: undefined,
      doctorTreatment: "banner",
      steps: [{ selector: '[data-doctor-notice="banner"]', action: "wait" }],
      note: "Banner: a warning Notice with Review across the top of every Settings page.",
    }),
    "treatment-inline": variant({
      doctorTreatment: "inline",
      steps: [{ selector: '[data-doctor-notice="inline"]', action: "wait" }],
      note: "Inline (shipped): the count and the line in the card's header only; nothing outside Personalization.",
    }),
  },
});
