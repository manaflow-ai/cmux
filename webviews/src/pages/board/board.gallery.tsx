// l10n-allow-file: gallery fixtures, not shipped UI.
// The team board (`cmux-page://cmux.board/`): the same BoardPage main.tsx mounts, over the mock
// `cmux.board.*` host and generated fixtures (fixtures.ts). The sizes are the ones the lane's proof
// names: 0, 3, 100 and 5,000 machines; the rest are the states a person meets.
import { useEffect, useState } from "react";
import { componentEntry } from "../../gallery/format";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { BoardPage } from "./BoardPage";
import { fixtureBoard } from "./fixtures";
import { MockBoardProvider } from "./mockProvider";
import { BoardStore } from "./store";
import type { BoardFilter } from "./model";
import type { BoardSnapshot } from "./types";

type Props = {
  machines?: number;
  snapshot?: BoardSnapshot;
  filter?: BoardFilter;
  query?: string;
  /** Click Stop on the first running row, and hold or refuse the answer. */
  stop?: "hold" | "refuse";
  /** No host serves the board. */
  unavailable?: boolean;
  ratePerSecond?: number;
};

function BoardGallery({ machines = 100, snapshot, filter, query, stop, unavailable, ratePerSecond = 0 }: Props) {
  const [provider] = useState(() => new MockBoardProvider({ machines, snapshot, ratePerSecond }));
  const [store] = useState(() => new BoardStore(unavailable ? null : provider));
  const [strings] = useState(() => createStrings(table));
  useEffect(() => {
    void store.start().then(() => {
      if (filter) store.setFilter(filter);
      if (query) store.setQuery(query);
      if (!stop) return;
      const first = store.getSnapshot().visible.find((id) => store.getRow(id)?.row.state === "running");
      if (!first) return;
      if (stop === "hold") provider.holdStop();
      else provider.stopRefusal = "The machine is busy with a snapshot. Try again in a minute.";
      void store.stopMachine(first);
    });
    return () => store.stop();
  }, [store, provider, filter, query, stop]);
  return <BoardPage store={store} strings={strings} />;
}

export default componentEntry<Props>({
  id: "pages.board",
  title: "Team board",
  area: "Pages",
  height: 640,
  widths: { narrow: 560, normal: 900, wide: 1280 },
  covers: ["page:cmux.board", "pages/board/BoardPage.tsx"],
  load: async () => BoardGallery,
  styles: async () => {
    await import("../shared/pageBase.css");
    await import("./styles.css");
  },
  variants: {
    "0-machines": {
      note: "A team with no machine: the totals read zero and the list says so.",
      props: { machines: 0 },
    },
    "3-machines": {
      note: "Three machines, two running and one paused, no degenerate data.",
      props: { machines: 3 },
    },
    "100-machines": {
      note: "100 machines across 4 members: agents waiting on a person first, then failed, running and paused, newest first.",
      props: { machines: 100 },
    },
    "5000-machines": {
      note: "5,000 machines and 200 members. Only the rows in view are in the DOM; open and scroll cost the same as at 3.",
      props: { machines: 5000 },
    },
    "no-owner": {
      note: "The No owner filter: machines with no creator, an empty one, or a creator who left the team.",
      props: { machines: 500, filter: "unowned" },
    },
    "waiting-on-a-person": {
      note: "The Waiting filter: machines where an agent waits on a person, oldest wait first.",
      props: { machines: 500, filter: "waiting" },
    },
    "degenerate-data": {
      note: "Negative, missing, NaN and infinite costs show a dash and count under Cost unknown; a 500-character name truncates; a machine listed twice shows once.",
      props: { snapshot: fixtureBoard({ machines: 60, degenerate: true }) },
    },
    stopping: {
      note: "Stop clicked on the first running machine; the host has not answered yet.",
      props: { machines: 20, stop: "hold" },
    },
    "stop-refused": {
      note: "The host refused Stop: the row says why in place of its last action.",
      props: { machines: 20, stop: "refuse" },
    },
    "search-no-match": {
      note: "A search that matches nothing.",
      props: { machines: 100, query: "nothing-matches-this" },
    },
    unavailable: {
      note: "A build whose host does not serve the board yet.",
      props: { unavailable: true },
    },
  },
});
