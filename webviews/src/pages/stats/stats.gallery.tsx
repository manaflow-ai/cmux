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
import type { Range } from "./types";

type Props = { kind?: MockStatsKind; range?: Range; failure?: { code: string; message: string } };

function StatsGallery({ kind = "busy", range = 84, failure }: Props) {
  // UTC, so every capture draws the same calendar wherever it runs.
  const [store] = useState(() => new StatsStore(new MockStatsProvider(kind, failure), () => 0));
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
