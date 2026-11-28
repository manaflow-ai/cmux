// l10n-allow-file: gallery fixtures, not shipped UI.
// Settings > Cloud > Spending (RFD 0080 "Spend controls"), gallery only: the card is in no Settings category yet,
// so the entry is experimental. Overage off (the placeholder default), on with a limit at 40%, the 80% banner and
// paused at the limit, each in the rows layout and the meter layout. Edits apply to local state.
import { componentEntry } from "../../../gallery/format";
import type { SpendCap } from "../../cloud/spendCap";
import type { SpendingSettings } from "../spending";
import type { SpendingLayout } from "./SpendingCard";

type Props = { settings: SpendingSettings; read: SpendCap | null; layout: SpendingLayout };

// A fixed period end, so captures never move with the clock.
const PERIOD_END = Date.UTC(2026, 11, 1, 8);
const read = (state: SpendCap["state"], spent: number, paused = false): SpendCap => ({
  state,
  spent_usd: spent,
  cap_usd: 50,
  period_end: PERIOD_END,
  checked_at: PERIOD_END - 86_400_000,
  pause_at: null,
  paused_at: paused ? PERIOD_END - 3_600_000 : null,
});
// The placeholder defaults (spending.ts DEFAULT_SPENDING), written out so the fixture never follows a change there.
const off: SpendingSettings = { overage_limit_usd: null, ask_above: { vcpu: 8, memory_gib: 16 } };
const on: SpendingSettings = { ...off, overage_limit_usd: 50 };

async function load() {
  const { SpendingCardDemo } = await import("./SpendingCard");
  return function Spending({ settings, read, layout }: Props) {
    return (
      <section className="settings-page" style={{ padding: 16 }}>
        <SpendingCardDemo
          key={JSON.stringify([settings, read, layout])}
          settings={settings}
          read={read}
          layout={layout}
        />
      </section>
    );
  };
}

export default componentEntry<Props>({
  id: "settings.spending",
  title: "Cloud: Spending",
  area: "Settings",
  experimental: true,
  height: 420,
  widths: { narrow: 520, normal: 760 },
  covers: ["pages/settings/components/SpendingCard.tsx", "pages/settings/spending.ts"],
  keywords: ["spend", "overage", "cap", "limit", "cloud", "billing", "vcpu"],
  load,
  styles: () => Promise.all([import("../page.css"), import("../tailwind.css")]),
  variants: {
    off: {
      note: "The placeholder default: overage off, ask above 8 vCPU · 16 GB. Past the plan's pool, cloud agents pause.",
      props: { settings: off, read: null, layout: "rows" },
    },
    "on-40": {
      note: "Overage on up to $50 a month, $20 spent (40%): no banner.",
      props: { settings: on, read: read("under", 20), layout: "rows" },
    },
    "near-80": {
      note: "The server says near (80%): one warning banner with Raise limit.",
      props: { settings: on, read: read("near", 40), layout: "rows" },
    },
    "paused-100": {
      note: "At the limit: Paused at your overage limit · Raise limit · Run on This Mac. Cloud agents pause, local ones keep running.",
      props: { settings: on, read: read("at_cap", 50, true), layout: "rows" },
    },
    "pool-spent-off": {
      note: "Overage off and the plan's pool used up: The plan's Cloud pool is used up · Turn on overage · Run on This Mac.",
      props: { settings: off, read: read("at_cap", 0, true), layout: "rows" },
    },
    "meter-on-40": {
      note: "Meter layout: the month's overage against the limit above the rows, at 40%.",
      props: { settings: on, read: read("under", 20), layout: "meter" },
    },
    "meter-near-80": {
      note: "Meter layout at 80%: the banner over a meter at 80%.",
      props: { settings: on, read: read("near", 40), layout: "meter" },
    },
    "meter-paused-100": {
      note: "Meter layout paused at the limit: a full meter under the paused banner.",
      props: { settings: on, read: read("at_cap", 50, true), layout: "meter" },
    },
    "ask-above-16": {
      note: "Overage off with the ask threshold raised to 16 vCPU · 32 GB.",
      props: { settings: { ...off, ask_above: { vcpu: 16, memory_gib: 32 } }, read: null, layout: "meter" },
    },
  },
});
