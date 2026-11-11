// l10n-allow-file: gallery fixtures, not shipped UI.
// Updates > Channels (ChannelsCard) mid-switch: the clicked Switch or Go Back stays shown with a
// spinner and the host's stage, a thin bar runs under its row (the download's share, else a quiet
// sweep), and every other Switch and Go Back waits. One variant per stage, and a refusal.
import { settingsPageEntry, type PageFixtureStep, type SettingsPageVariant } from "../../gallery/format";
import { mockChannels, mockGoBack } from "./mockChannels";
import type { ChannelsProgress } from "./ops";

const running = (selector: string): PageFixtureStep => ({ selector: `${selector}[data-running]`, action: "wait" });
const nightlyRow = (build: string) => `[data-channel="nightly"] [data-channel-build="${build}"]`;
const variant = (progress: ChannelsProgress, wait: PageFixtureStep, note: string): SettingsPageVariant => ({
  section: "updates",
  focus: "channels",
  options: { values: { "updates.channel": "nightly" } },
  channels: { ...mockChannels, progress },
  channelSwitch: mockGoBack,
  steps: [wait],
  note,
});

export default settingsPageEntry({
  id: "pages.settings-channels-switch",
  title: "Settings Channels Switch",
  area: "Settings",
  height: 760,
  covers: ["pages/settings/components/ChannelsCard.tsx"],
  anchors: [{ selector: '[data-card="channels"]' }],
  variants: {
    downloading: variant(
      { build: "3422", label: "Downloading… 42%", fraction: 0.42 },
      running(nightlyRow("3422")),
      "A Switch to a build this Mac never kept: its download's share in the button and the bar; every other button waits.",
    ),
    checking: variant(
      { build: "3422", label: "Checking it can open your sessions…", fraction: null },
      running(nightlyRow("3422")),
      "The download landed and the host checks it: the stage in the button, a faint sweep under the row.",
    ),
    restarting: variant(
      { build: "3418", label: "Restarting…", fraction: null },
      running('[data-channel-switch="nightly"] .row'),
      "Go Back into the kept build: no download, straight to the restart; the Switches below wait.",
    ),
    refused: {
      section: "updates",
      focus: "channels",
      options: { values: { "updates.channel": "nightly" } },
      switchRefusal: "That build is no longer offered for download.",
      steps: [
        { selector: `${nightlyRow("3422")} [data-channel-switch-build]`, action: "click" },
        { selector: `${nightlyRow("3422")} .row-error`, action: "wait" },
      ],
      note: "The host refused the Switch: its reason in that build's row, and every button is back.",
    },
  },
});
