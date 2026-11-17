// l10n-allow-file: gallery fixtures (sample widget content), not shipped UI.
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import type { WidgetFixtureProps } from "./NewTabWidgets.fixture";

const open: Play = async (ctx) => {
  await ctx.waitFor(
    () =>
      ctx.document.querySelectorAll(".nt-widget-preview [data-scene-node], .nt-widget-preview .cmux-app-scene-root")
        .length > 0,
  );
};

// The Add Widget gallery, compared with Apple's (ios16-lock-screen-add-widgets-sheet: live previews
// in a sheet, picked with a tap): every installed widget for the New Tab, drawn live from sample data
// (`context.preview`) at each of its sizes.
export default componentEntry<WidgetFixtureProps>({
  id: "new-tab.widget-gallery",
  title: "New Tab Add Widget gallery",
  area: "New Tab",
  height: 720,
  widths: { normal: 760, wide: 900 },
  covers: ["agent-session/acpmux/newtab/AddWidgetGallery.tsx"],
  load: async () => (await import("./NewTabWidgets.fixture")).NewTabWidgetsFixture,
  styles: () => Promise.all([import("./screen.css"), import("./widgets.css")]),
  variants: {
    rows: {
      props: { editing: true, gallery: true, galleryLook: "rows", tiles: [] },
      note: "Shipped: each widget's row shows it live at every size it offers (macOS's gallery)",
      play: open,
    },
    sizes: {
      props: { editing: true, gallery: true, galleryLook: "sizes", tiles: [] },
      note: "One size at a time, picked with size chips (iOS's gallery)",
      play: open,
    },
    grid: {
      props: { editing: true, gallery: true, galleryLook: "grid", tiles: [] },
      note: "Every preview in one tile grid (the Lock Screen Add Widgets sheet)",
      play: open,
    },
  },
});
