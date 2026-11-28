// l10n-allow-file: gallery fixtures, not shipped UI.
// The Stats page (cmux-page://cmux.stats/, hq#1920): the same StatsPage main.tsx mounts, over the
// mock `cmux.stats.summary` provider instead of the host bridge.
import { useEffect, useState } from "react";
import { componentEntry } from "../../gallery/format";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { MockStatsProvider, type MockStatsKind, type MockUsageKind } from "./mockProvider";
import { StatsPage } from "./StatsPage";
import { StatsStore } from "./store";
import type { Range, StatsSummary } from "./types";

type Props = {
  kind?: MockStatsKind;
  range?: Range;
  longestStreak?: number;
  failure?: { code: string; message: string };
  usage?: MockUsageKind;
  /** Overrides acpmux's busy (clock) time as a share of agent time; null drops the field (an older acpmux). */
  busyShare?: number | null;
};

function StatsGallery({ kind = "busy", range = 84, longestStreak, failure, usage = "on", busyShare }: Props) {
  // UTC, so every capture draws the same calendar wherever it runs.
  const [store] = useState(() => {
    const provider = new MockStatsProvider(kind, failure, usage);
    if (longestStreak !== undefined || busyShare !== undefined) {
      const call = provider.call.bind(provider);
      provider.call = async <R,>(op: string, params: unknown): Promise<R> => {
        let summary = await call<StatsSummary>(op, params);
        if (longestStreak !== undefined)
          summary = { ...summary, streak: { ...summary.streak, longest: longestStreak } };
        if (busyShare !== undefined) {
          const { busyMs: _dropped, ...rest } = summary;
          summary = busyShare === null ? rest : { ...rest, busyMs: Math.round(summary.workingMs * busyShare) };
        }
        return summary as R;
      };
    }
    return new StatsStore(provider, () => 0);
  });
  const [strings] = useState(() => createStrings(table));
  useEffect(() => {
    void store.setRange(range);
  }, [store, range]);
  return <StatsPage store={store} strings={strings} />;
}

export default componentEntry<Props>({
  id: "pages.stats",
  title: "Stats",
  area: "Pages",
  experimental: true,
  height: 760,
  widths: { narrow: 360, normal: 640, wide: 900 },
  covers: ["page:cmux.stats", "pages/stats/StatsPage.tsx"],
  load: async () => StatsGallery,
  styles: async () => {
    await import("../shared/pageBase.css");
    await import("./styles.css");
  },
  variants: {
    quarter: { note: "Twelve weeks of a working machine: three agents, weekends light.", props: {} },
    week: { note: "The last seven days.", props: { range: 7 } },
    "streak-ones": {
      note: "The longest-streak detail with narrow proportional digits.",
      props: { longestStreak: 11 },
    },
    "streak-eights": {
      note: "The same detail with wide proportional digits.",
      props: { longestStreak: 88 },
    },
    "streak-max": {
      note: "The maximum 366-day lookback at the existing caption size.",
      props: { longestStreak: 366 },
    },
    empty: { note: "No agent has run in range yet.", props: { kind: "empty" } },
    "payoff-many": {
      note: "Parallel payoff with many agents at once: 7.9 hours of agent work per clock hour.",
      props: { busyShare: 1 / 7.94 },
    },
    "payoff-solo": {
      note: "Parallel payoff with one agent at a time: 1.0x, said plainly.",
      props: { busyShare: 1 },
    },
    "payoff-older-acpmux": {
      note: "An acpmux without busy time: no payoff band, the tiles as before.",
      props: { busyShare: null },
    },
    "usage-off": {
      note: "Usage Patterns with the setting off (the default): the section says how to turn it on.",
      props: { usage: "off" },
    },
    "usage-older-acpmux": {
      note: "An acpmux without usage patterns: no section at all.",
      props: { usage: "none" },
    },
    "usage-week": {
      note: "Usage Patterns on, at the narrow week range: commands, splits, agents, connections.",
      props: { usage: "on", range: 7 },
    },
    failed: {
      note: "acpmux did not answer: the page reads again on its own and, past the deadline, says the app's words in one quiet line with no button.",
      props: { failure: { code: "cmux.stats.unavailable", message: "The agent service is not running." } },
    },
    unreadable: {
      note: "acpmux answered with an error: read again on its own; past the deadline the page's quiet line, never acpmux's words.",
      props: { failure: { code: "cmux.stats.failed", message: "stats: No such file or directory (os error 2)" } },
    },
  },
});
