// l10n-allow-file: gallery fixtures (sample widget content), not shipped UI.
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import type { WidgetFixtureProps } from "./NewTabWidgets.fixture";

const editing: Play = async (ctx) => {
  await ctx.waitFor(
    () =>
      ctx.document.querySelectorAll(
        ".nt-widget-frame .nt-widget-card [data-scene-node], .nt-widget-frame .cmux-app-scene-root",
      ).length > 0,
  );
};

// Edit mode, compared with Apple's Home Screen editing (hig-size-grid-ipad-home-screen): tiles
// jiggle (still under Reduce Motion), each with a minus badge; the variants differ in how a tile
// takes a new size. The meter shows each tile's refresh interval, ticks and held batches.
export default componentEntry<WidgetFixtureProps>({
  id: "new-tab.widget-edit",
  title: "New Tab widget edit mode",
  area: "New Tab",
  height: 600,
  widths: { narrow: 420, normal: 720, wide: 900 },
  covers: [
    "agent-session/acpmux/newtab/WidgetEditing.tsx#GridWidgetFrame",
    "agent-session/acpmux/newtab/widgetEditingModel.ts",
  ],
  load: async () => (await import("./NewTabWidgets.fixture")).NewTabWidgetsFixture,
  styles: () => Promise.all([import("./screen.css"), import("./widgets.css")]),
  variants: {
    badge: {
      props: { editing: true, editLook: "badge" },
      note: "Shipped: minus badge top left, a size menu bottom right, drag to arrange",
      play: editing,
    },
    corner: {
      props: { editing: true, editLook: "corner" },
      note: "A resize corner that steps to the widget's next size",
      play: editing,
    },
    chips: {
      props: { editing: true, editLook: "chips" },
      note: "The widget's sizes as chips under each tile",
      play: editing,
    },
  },
});
