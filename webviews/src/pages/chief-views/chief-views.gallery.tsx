// l10n-allow-file: gallery fixtures, not shipped UI.
// The Chief view gallery (cmux-page://cmux.chief-views/): the same ChiefViewsPage main.tsx mounts,
// over the mock `cmux.chief_views.*` provider instead of the host bridge. One variant per view in
// the pane, the split and sidebar placements, the gallery open, and the empty and unavailable states.
import { useEffect, useState } from "react";
import { componentEntry } from "../../gallery/format";
import { createStrings } from "../shared/i18n";
import { ChiefViewsPage } from "./ChiefViewsPage";
import table from "./generated/strings.json";
import { FIXTURE_NOW, MockChiefViewsProvider, type MockChiefViewsKind } from "./mockProvider";
import { CHIEF_VIEWS } from "./registry";
import { ChiefViewsStore, type Layout } from "./store";

type Props = { kind?: MockChiefViewsKind; layout?: Layout; catalog?: boolean };

const ALL = CHIEF_VIEWS.map((view) => view.id);
const pane = (main: string): Layout => ({ enabled: ALL, main });

function ChiefViewsGallery({ kind = "busy", layout, catalog }: Props) {
  const [store] = useState(
    () =>
      new ChiefViewsStore(new MockChiefViewsProvider(kind), CHIEF_VIEWS, {
        layout,
        catalog,
        persist: false,
      }),
  );
  const [strings] = useState(() => createStrings(table));
  useEffect(() => {
    void store.start();
    return () => store.stop();
  }, [store]);
  return <ChiefViewsPage store={store} strings={strings} now={FIXTURE_NOW} />;
}

export default componentEntry<Props>({
  id: "pages.chief-views",
  title: "Chief view gallery",
  area: "Home and Chief",
  experimental: true,
  height: 900,
  widths: { narrow: 420, normal: 760, wide: 1180 },
  covers: [
    "page:cmux.chief-views",
    "pages/chief-views/ChiefViewsPage.tsx",
    "pages/chief-views/parts.tsx",
    "pages/chief-views/views/WhereIsEverybody.tsx",
    "pages/chief-views/views/AgentBoard.tsx",
    "pages/chief-views/views/Fleet.tsx",
    "pages/chief-views/views/Landing.tsx",
    "pages/chief-views/views/Timeline.tsx",
  ],
  keywords: ["chief", "home", "agents", "fleet", "landing", "timeline", "board", "views", "gallery"],
  load: async () => ChiefViewsGallery,
  styles: async () => {
    await import("../shared/pageBase.css");
    await import("./styles.css");
  },
  variants: {
    "where-is-everybody": {
      note: "The default and only view on at first: nine agents on four machines, what needs you first.",
      props: { layout: { enabled: ["where-is-everybody"], main: "where-is-everybody" } },
    },
    "agent-board": {
      note: "Agent board: Working, Needs you, Ready to land, Landed today.",
      props: { layout: pane("agent-board") },
    },
    fleet: {
      note: "Fleet: six minis from the CI dashboard, one unreachable.",
      props: { layout: pane("fleet") },
    },
    landing: {
      note: "Landing: open, ready to land, CI red, merged today, with owner chips.",
      props: { layout: pane("landing") },
    },
    timeline: {
      note: "Timeline: today's events across agents and PRs, newest first.",
      props: { layout: pane("timeline") },
    },
    gallery: {
      note: "The gallery open: every view with its description, its switch and where to open it.",
      props: {
        layout: { enabled: ["where-is-everybody"], main: "where-is-everybody" },
        catalog: true,
      },
    },
    split: {
      note: "Where is everybody in the pane, Fleet as a split beside it.",
      props: {
        layout: {
          enabled: ALL,
          main: "where-is-everybody",
          side: { id: "fleet", placement: "split" },
        },
      },
    },
    sidebar: {
      note: "Agent board in the pane, Timeline as a sidebar.",
      props: {
        layout: {
          enabled: ALL,
          main: "agent-board",
          side: { id: "timeline", placement: "sidebar" },
        },
      },
    },
    "fleet-unset": {
      note: "Fleet before a dashboard is named: the field to name one.",
      props: { kind: "fleet-unset", layout: pane("fleet") },
    },
    empty: {
      note: "Nothing running and no view on: the gallery opens by itself.",
      props: { kind: "empty", layout: { enabled: [] } },
    },
  },
});
