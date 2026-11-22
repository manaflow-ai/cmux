// l10n-allow-file: gallery fixtures, not shipped UI.
// Settings > Advanced > Extensions (ExtensionsCard): each installed extension's meter (the daemon's
// apps.meters) and, in safe mode, the bisect. One variant per state the card draws differently.
import { settingsPageEntry, type PageFixtureStep, type SettingsPageVariant } from "../../gallery/format";
import type { ExtensionMeter } from "./ops";

const meter = (app: string, extra: Partial<ExtensionMeter> = {}): ExtensionMeter => ({
  app,
  step: "normal",
  host: "running",
  crashes: 0,
  mounts: 2,
  widgets: 1,
  slowedMounts: 0,
  batches: { in: 1240, out: 1198 },
  held: 42,
  ...extra,
});
const meters = [
  meter("acme/notes"),
  meter("local/pr-widget", { step: "slowed", slowedMounts: 1, held: 310 }),
  meter("local/spy", { step: "paused", paused: "over its batch rate", host: "waiting", crashes: 2 }),
];
const card: PageFixtureStep = { selector: '[data-card="extensions"]', action: "wait" };
const start: PageFixtureStep = { selector: '[data-bisect-step="start"]', action: "click" };
const bisectWait: PageFixtureStep = { selector: '[data-bisect-step="good"]', action: "wait" };
const variant = (safeMode: boolean, note: string, steps: PageFixtureStep[] = []): SettingsPageVariant => ({
  section: "advanced",
  options: { extensions: { meters, safeMode } },
  steps: [card, ...steps],
  note,
});

export default settingsPageEntry({
  id: "pages.settings-extensions",
  title: "Settings Extensions",
  area: "Settings",
  height: 760,
  covers: ["pages/settings/components/ExtensionsCard.tsx"],
  anchors: [{ selector: '[data-card="extensions"]' }],
  variants: {
    meters: variant(
      false,
      "Three extensions: normal, slowed by the budget, and paused after crashes, each with its host and counts.",
    ),
    safeMode: variant(true, "Safe mode is on: the bisect row offers Start under the meters."),
    bisecting: variant(
      true,
      "A bisect running: the half that runs now, how many are left, and It Works / It Broke / End.",
      [start, bisectWait],
    ),
  },
});
