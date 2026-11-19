// l10n-allow-file: synthetic gallery fixture, not shipped UI.
// The New Tab page's depth layer (depthBackground.experiment.ts, DepthBackground.tsx): the Cards
// page with three chat cards over each arm. Leo's reference: "bold dark cards, and a live layer
// behind the UI for depth". The `backdrop` arm reads best with the stage's background control set to
// a picture (`background=busy`), as a window with "Set Background…" draws it.
import { agentPaneEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import { CWD, manySessions, noChat } from "../../../gallery/fixtures/acpmux";
import { newTabDepth } from "./depthBackground.experiment";

const newTab = {
  newTab: {
    layout: "b",
    kind: "agent",
    cwd: CWD,
    home: "/Users/you",
    lastAgent: "claude",
    template: "cards",
  },
  newSession: true,
};

const ready = (ctx: PlayContext) => ctx.waitFor(() => ctx.document.querySelectorAll(".nt-cards .nt-card").length > 0);

export default agentPaneEntry({
  id: "agent-pane.new-tab-depth",
  title: "New Tab depth layer",
  area: "New Tab",
  experimental: true,
  height: 640,
  experiment: {
    definition: newTabDepth,
    script: [
      { name: "page drawn", run: ready },
      {
        name: "hover a card",
        run: async (ctx) => {
          await ready(ctx);
          await ctx.hover({ selector: ".nt-cards .nt-card" });
        },
      },
    ],
  },
  covers: ["agent-session/acpmux/newtab/DepthBackground.tsx#DepthBackground"],
  variants: {
    cards: {
      note: "The Cards page with three chat cards over the arm's depth layer.",
      ready: newTab,
      snapshot: noChat(manySessions(6)),
      play: ready,
    },
  },
});
