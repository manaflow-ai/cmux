// l10n-allow-file: gallery fixtures, not shipped UI.
// Updates > Web UI (WebUpdatesCard): the web UI a NIGHTLY build serves between app updates, from
// the host lists' `web_updates`. One variant per state the card words differently.
import { settingsPageEntry, type PageFixtureStep, type SettingsPageVariant } from "../../gallery/format";
import type { WebUpdatesState } from "./ops";

const bundled: WebUpdatesState = {
  channel: "every-merge",
  phase: "idle",
  served: null,
  active: null,
  previous: null,
  pending: null,
  last_check: 1_792_000_000,
  refusal: "not_newer",
};
const update = { commit: "765fb01ac29f4e1d8b3a90c2f5e6d7a8b9c0d1e2", committed_at: 1_791_990_000 };
const earlier = { commit: "edda5738fae172c3d4e5f60718293a4b5c6d7e8f", committed_at: 1_791_900_000 };
// Focusing the card's Check Now scrolls it into view (it follows the Updates groups).
const focusCard: PageFixtureStep = {
  selector: '[data-card="web-updates"] [data-web-updates="check"]',
  action: "focus",
};
const card = (phase: string): PageFixtureStep => ({
  selector: `[data-card="web-updates"][data-phase="${phase}"]`,
  action: "wait",
});
const variant = (state: WebUpdatesState, note: string): SettingsPageVariant => ({
  section: "updates",
  host: { web_updates: state },
  steps: [card(state.phase), focusCard],
  note,
});

export default settingsPageEntry({
  id: "pages.settings-web-updates",
  title: "Settings Web UI",
  area: "Settings",
  height: 760,
  covers: ["pages/settings/components/WebUpdatesCard.tsx"],
  anchors: [{ selector: '[data-card="web-updates"]' }],
  variants: {
    bundled: variant(bundled, "The built-in web UI: Built in, up to date, Roll Back disabled."),
    active: variant(
      { ...bundled, served: update, active: update, previous: earlier },
      "An update served: its short commit and commit date; Roll Back names the update before it.",
    ),
    pending: variant(
      { ...bundled, served: earlier, active: update, previous: earlier, pending: "update" },
      "A new update is ready: the served version stays the one pages run until it loads, the next time cmux is in the background.",
    ),
    failed: variant(
      { ...bundled, served: update, active: update, phase: "failed", refusal: "offline" },
      "The last check failed: the card says the server was not reached and that cmux tries again.",
    ),
  },
});
