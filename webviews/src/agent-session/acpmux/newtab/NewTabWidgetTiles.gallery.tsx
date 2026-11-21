// l10n-allow-file: gallery fixtures (sample widget content), not shipped UI.
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import type { WidgetFixtureProps } from "./NewTabWidgets.fixture";

const drawn: Play = async (ctx) => {
  await ctx.waitFor(
    () =>
      ctx.document.querySelectorAll(".nt-widget-card [data-scene-node], .nt-widget-card .cmux-app-scene-root").length >
      0,
  );
};
const stale: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".nt-widget-card[data-stale]") !== null);
};

// The tile card, compared with Apple's references (cmux-design-references apple-widgets/web):
// hig-size-grid-ipad-home-screen (the 1x1 / 2x1 / 2x2 grid and the continuous corner) and
// macos-sonoma-widgets-tinted-behind-window (the desktop material and its tint).
export default componentEntry<WidgetFixtureProps>({
  id: "new-tab.widget-tiles",
  title: "New Tab widget tiles",
  area: "New Tab",
  height: 560,
  widths: { narrow: 420, normal: 720, wide: 900 },
  covers: [
    "agent-session/acpmux/newtab/NewTabWidgets.tsx#NewTabWidgets",
    "agent-session/acpmux/newtab/NewTabWidgets.tsx#WidgetTile",
  ],
  load: async () => (await import("./NewTabWidgets.fixture")).NewTabWidgetsFixture,
  styles: () => Promise.all([import("./screen.css"), import("./widgets.css")]),
  variants: {
    glass: {
      props: { tileLook: "glass" },
      note: "Shipped: translucent material cards on one tile unit (macOS Sonoma desktop widgets)",
      play: drawn,
    },
    solid: {
      props: { tileLook: "solid" },
      note: "Opaque cards with a hairline edge (the iPad Home Screen size grid)",
      play: drawn,
    },
    tinted: {
      props: { tileLook: "tinted" },
      note: "Accent-tinted material (Sonoma widgets behind a window)",
      play: drawn,
    },
    stale: {
      props: { tileLook: "glass", stale: "w2" },
      note: "Let it crash: the weather widget threw; its last scene stays, dimmed, with Updating...",
      play: stale,
    },
  },
});
