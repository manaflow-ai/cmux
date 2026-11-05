// l10n-allow-file: gallery fixtures, not shipped UI.
// The Stats page (cmux-page://cmux.stats/, hq#1920): the same StatsPage main.tsx mounts, over the
// mock `cmux.stats.summary` provider instead of the host bridge.
import { useEffect, useState } from "react";
import { componentEntry } from "../../gallery/format";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { MockStatsProvider, type MockStatsKind } from "./mockProvider";
import { StatsPage } from "./StatsPage";
import { StatsStore } from "./store";
import type { Range, StatsSummary } from "./types";

type Props = {
  kind?: MockStatsKind;
  range?: Range;
  longestStreak?: number;
  failure?: { code: string; message: string };
};

function StatsGallery({ kind = "busy", range = 84, longestStreak, failure }: Props) {
  // UTC, so every capture draws the same calendar wherever it runs.
  const [store] = useState(() => {
    const provider = new MockStatsProvider(kind, failure);
    if (longestStreak !== undefined) {
      const call = provider.call.bind(provider);
      provider.call = async <R,>(op: string, params: unknown): Promise<R> => {
        const summary = await call<StatsSummary>(op, params);
        return { ...summary, streak: { ...summary.streak, longest: longestStreak } } as R;
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
    failed: {
      note: "acpmux did not answer.",
      props: { failure: { code: "cmux.stats.unavailable", message: "The agent service is not running." } },
    },
    unreadable: {
      note: "acpmux answered with an error; the page words it, never acpmux.",
      props: { failure: { code: "cmux.stats.failed", message: "stats: No such file or directory (os error 2)" } },
    },
  },
});
