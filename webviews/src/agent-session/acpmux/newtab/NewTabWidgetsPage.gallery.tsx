// l10n-allow-file: gallery fixtures (sample widget content), not shipped UI.
import type { ComponentProps } from "react";
import { componentEntry } from "../../../gallery/format";
import type { Play } from "../../../gallery/play";
import type { NewTabPageWithWidgetsFixture } from "./NewTabWidgets.fixture";

const drawn: Play = async (ctx) => {
  await ctx.waitFor(
    () =>
      ctx.document.querySelector(".nt-composer") !== null &&
      ctx.document.querySelectorAll(".nt-widget-card .cmux-app-scene-root").length >= 5,
  );
};

// The whole New Tab page with the person's widgets: the composer where it always sits and a full
// grid (two small, two medium and one large tile) beside the page's own lists, never over the
// composer (an extension's view over the composer has its own room, `tabs.newTabApp`).
export default componentEntry<ComponentProps<typeof NewTabPageWithWidgetsFixture>>({
  id: "new-tab.widgets-page",
  title: "New Tab page with widgets",
  area: "New Tab",
  height: 1100,
  pane: true,
  widths: { narrow: 520, normal: 900, wide: 1200 },
  covers: [
    "agent-session/acpmux/newtab/NewTabScreen.tsx",
    "agent-session/acpmux/newtab/NewTabWidgets.tsx#NewTabWidgets",
  ],
  load: async () => (await import("./NewTabWidgets.fixture")).NewTabPageWithWidgetsFixture,
  styles: () => Promise.all([import("../styles.css"), import("./screen.css"), import("./widgets.css")]),
  variants: {
    minimal: {
      props: { template: "minimal" },
      note: "Minimal: the composer, then the full widget grid under it",
      play: drawn,
    },
    cards: {
      props: { template: "cards" },
      note: "Cards: the composer, the widget grid, then the recent chats",
      play: drawn,
    },
  },
});
