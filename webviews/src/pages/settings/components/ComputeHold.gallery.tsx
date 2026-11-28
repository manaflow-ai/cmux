// l10n-allow-file: gallery fixtures (sample team members), not shipped UI.
// Settings > Team > Compute: three ways to offer the team's hold for its people's machines (how long
// a machine someone is chatting on stays ready after a reply before it may pause). On trial here only:
// the app's card passes no `holdControl`, so Settings draws none of them. Clicks run the mock backend
// (mockAllotments.ts), so each variant can be set and cleared.
import { componentEntry } from "../../../gallery/format";
import type { HoldControl } from "./ComputeCard";

type Props = { control: HoldControl; seconds?: 300 | 900 | 1800 };

async function load() {
  const [{ ComputeCardDemo }, { mockAllotments, runMockAllotment }] = await Promise.all([
    import("./ComputeCard"),
    import("../mockAllotments"),
  ]);
  return function ComputeHold({ control, seconds }: Props) {
    const view =
      seconds === undefined
        ? mockAllotments.hold
        : runMockAllotment(mockAllotments.hold, { person_hold_seconds: seconds });
    return (
      <section className="settings-page" style={{ padding: 16 }}>
        <ComputeCardDemo
          key={`${control}-${seconds ?? "off"}`}
          view={view}
          layout="ledger"
          holdControl={control}
          answer={runMockAllotment}
        />
      </section>
    );
  };
}

export default componentEntry<Props>({
  id: "settings.compute-hold",
  title: "Compute: hold for people",
  area: "Settings",
  experimental: true,
  height: 720,
  widths: { narrow: 520, normal: 760 },
  covers: ["pages/settings/components/ComputeCard.tsx", "pages/settings/computeAllotment.ts"],
  keywords: ["allotment", "team", "cloud", "pause", "wake", "idle", "ready"],
  load,
  styles: () => Promise.all([import("../page.css"), import("../tailwind.css")]),
  variants: {
    choices: { note: "A: every choice in a row, none set.", props: { control: "choices" } },
    "choices-15": { note: "A with 15 minutes set.", props: { control: "choices", seconds: 900 } },
    switch: { note: "B: one switch, off. On holds for 30 minutes.", props: { control: "switch" } },
    "switch-on": { note: "B with the switch on.", props: { control: "switch", seconds: 1800 } },
    advanced: { note: "C: the choices under Advanced, out of the way.", props: { control: "advanced" } },
  },
});
