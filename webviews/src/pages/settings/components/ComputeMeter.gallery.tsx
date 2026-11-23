// l10n-allow-file: gallery fixtures (sample team members), not shipped UI.
// Settings > Team > Compute, layout B Meter (one of three on trial; the card is in no Settings category
// yet, so the entry is experimental). One bar of the month's use cut into member segments, ticks at the allotment and the hard cap, the dial as - / + on the allotment tick, members as the legend.
// Clicks run the mock backend (mockAllotments.ts), so a variant can be scaled, held and switched to Auto.
import { componentEntry } from "../../../gallery/format";
import type { MockAllotmentState } from "../mockAllotments";

type Props = { state: MockAllotmentState };

async function load() {
  const [{ ComputeCardDemo }, { mockAllotments, runMockAllotment }] = await Promise.all([
    import("./ComputeCard"),
    import("../mockAllotments"),
  ]);
  return function ComputeMeter({ state }: Props) {
    return (
      <section className="settings-page" style={{ padding: 16 }}>
        <ComputeCardDemo key={state} view={mockAllotments[state]} layout="meter" answer={runMockAllotment} />
      </section>
    );
  };
}

export default componentEntry<Props>({
  id: "settings.compute-meter",
  title: "Compute: B Meter",
  area: "Settings",
  experimental: true,
  height: 640,
  widths: { narrow: 520, normal: 760 },
  covers: ["pages/settings/components/ComputeCard.tsx", "pages/settings/computeAllotment.ts"],
  keywords: ["allotment", "team", "cloud", "usage", "billing"],
  load,
  styles: () => Promise.all([import("../page.css"), import("../tailwind.css")]),
  variants: {
    "proposal-up": {
      note: "Austin passed the allotment 4 times: Scale up is proposed.",
      props: { state: "proposalUp" },
    },
    "proposal-down": {
      note: "3 of 7 used nothing in 14 days: Scale down is proposed.",
      props: { state: "proposalDown" },
    },
    hold: { note: "Usage fits the allotment: Hold.", props: { state: "hold" } },
    empty: { note: "No one has used Cloud yet: Hold, disabled.", props: { state: "empty" } },
    "auto-on": { note: "Auto on: the scheduler scales up by itself.", props: { state: "autoOn" } },
  },
});
