// l10n-allow-file: deterministic, public-safe gallery app fixtures.
import type { ComponentProps } from "react";
import { componentEntry } from "../../../gallery/format";
import { MOCK_APP_PANELS, MOCK_NEW_TAB_WIDGETS, MockAppPanelsClient } from "../../../apps/scene/panelsMock";
import type { AppWidgets } from "./AppWidgets";

const host = (widgets: typeof MOCK_NEW_TAB_WIDGETS) => {
  const client = new MockAppPanelsClient();
  client.newTabWidgets = widgets;
  return client;
};

export default componentEntry<ComponentProps<typeof AppWidgets>>({
  id: "agent-pane.new-tab-app-widgets",
  title: "New Tab app widgets",
  area: "Agent pane",
  covers: ["agent-session/acpmux/newtab/AppWidgets.tsx#AppWidgets"],
  styles: () => Promise.all([import("../styles.css"), import("./screen.css")]),
  load: () => import("./AppWidgets").then((module) => module.AppWidgets),
  widths: { narrow: 320, normal: 620, wide: 820 },
  height: 320,
  anchors: [{ selector: ".nt-app-widgets" }],
  variants: {
    one: {
      note: "One app's widget (cmux.newtab.widget/1): a quiet card under the composer.",
      props: { client: host(MOCK_NEW_TAB_WIDGETS) },
    },
    two: {
      note: "Two apps' widgets share a row when the pane is wide and stack when narrow.",
      props: {
        client: host([
          ...MOCK_NEW_TAB_WIDGETS,
          { ...MOCK_APP_PANELS[1]!, app: "samples/today", section: "cmux.newtab.widget/1", title: "Today" },
        ]),
      },
    },
    none: {
      note: "No app implements a New Tab widget: nothing is drawn and the page is unchanged.",
      props: { client: host([]) },
    },
  },
});
