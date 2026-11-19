// l10n-allow-file: gallery fixtures (public-safe sample start traces), not shipped UI.
// Cloud start timings (DEV and NIGHTLY, the Cloud page's #/timings): the same StartTimings the page
// draws, over the mock Cloud server's start traces. Three looks side by side (lanes, bands, columns;
// bands ships), then the states of the chosen look.
import { useEffect, useState } from "react";
import { componentEntry } from "../../gallery/format";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { MockCloudProvider } from "./mockProvider";
import { StartTimings, type StartTimingsLook } from "./StartTimings";
import { StartTraceStore } from "./startTraceStore";
import { emptyTraceList, sampleTraceList, sampleTraces } from "./startTraceFixtures";

type Props = {
  look?: StartTimingsLook;
  /** Which sample start the waterfall shows (index into sampleTraces). */
  pick?: number;
  empty?: boolean;
  failure?: boolean;
};

function StartTimingsGallery({ look = "bands", pick = 0, empty = false, failure = false }: Props) {
  const [now] = useState(() => Date.now());
  const [store] = useState(() => {
    const provider = new MockCloudProvider({ unsupported: [] });
    const traces = sampleTraces(now);
    provider.startTraces = { list: empty ? emptyTraceList(now) : sampleTraceList(now, traces), traces };
    if (failure) {
      provider.failNext = "cmux.cloud.start_trace.list";
    }
    return { store: new StartTraceStore(provider), pick: traces[pick]?.trace };
  });
  const [strings] = useState(() => createStrings(table));
  useEffect(() => {
    void store.store.refresh().then(() => (pick > 0 && store.pick ? store.store.select(store.pick) : undefined));
  }, [store, pick]);
  return <StartTimings store={store.store} strings={strings} look={look} now={now} />;
}

export default componentEntry<Props>({
  id: "pages.cloud-start-timings",
  title: "Cloud start timings",
  area: "Pages",
  experimental: true,
  height: 720,
  widths: { narrow: 420, normal: 760, wide: 1040 },
  covers: ["pages/cloud/StartTimings.tsx"],
  load: async () => StartTimingsGallery,
  styles: async () => {
    await import("../shared/pageBase.css");
    await import("./styles.css");
  },
  variants: {
    bands: {
      note: "The shipped look: each hop's bar over the day's p50 to p95 band, its numbers beside it; boot is slower than p95.",
      props: { look: "bands" },
    },
    lanes: {
      note: "Look 2: the waterfall alone, then a separate table of each hop's p50 and p95 over the day.",
      props: { look: "lanes" },
    },
    columns: {
      note: "Look 3: the day's starts in a list beside the waterfall and the p50 and p95 table.",
      props: { look: "columns" },
    },
    spare: {
      note: "A claimed spare: no restore, short boot.",
      props: { look: "bands", pick: 1 },
    },
    "cli-click": {
      note: "A CLI start that timed its own click, so the click row shows and the note does not; boot far past p95.",
      props: { look: "bands", pick: 2 },
    },
    "still-running": {
      note: "A resume that has not reached agent auth or its first token yet.",
      props: { look: "bands", pick: 3 },
    },
    empty: {
      note: "No Cloud starts in the last day.",
      props: { empty: true },
    },
    failed: {
      note: "The read failed: the error and Refresh.",
      props: { failure: true },
    },
  },
});
