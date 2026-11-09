// l10n-allow-file: synthetic gallery fixture, not shipped UI.
// The New Tab composer's icon column (iconColumn.experiment.ts, Leo 2026-11-07): the folder chip's
// icon over the box, the + glyph and the permission mode's shield under it, in the no-project,
// project and machine-picked states. test/newtab-icon-column.test.ts measures the three centers.
import { agentPaneEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import { CWD, noChat } from "../../../gallery/fixtures/acpmux";
import { newTabIconColumn } from "./iconColumn.experiment";

const newTab = (fields: Record<string, unknown> = {}) => ({
  newTab: {
    layout: "b",
    kind: "agent",
    cwd: CWD,
    home: "/Users/you",
    lastAgent: "claude",
    template: "minimal",
    ...fields,
  },
  newSession: true,
});

const ready = (ctx: PlayContext) =>
  ctx.waitFor(
    () =>
      ctx.document.querySelector(".nt-above .acpmux-location-picker .ui-ghost-icon") !== null &&
      ctx.document.querySelector(".nt-box .acpmux-composer-plus svg") !== null &&
      ctx.document.querySelector(".nt-foot .acpmux-access-trigger svg") !== null,
  );

export default agentPaneEntry({
  id: "agent-pane.new-tab-icon-column",
  title: "New Tab icon column",
  area: "New Tab",
  height: 360,
  experiment: {
    definition: newTabIconColumn,
    script: [{ name: "measure the icon column", run: ready }],
  },
  covers: ["agent-session/acpmux/newtab/NewTabScreen.tsx#NewTabScreen"],
  variants: {
    "no-project": {
      note: "No project: the folder chip offers a folder; its icon, + and the shield share one center line.",
      ready: newTab({ cwd: "/Users/you", projects: [] }),
      snapshot: noChat([], { listedSessions: true }),
      play: ready,
    },
    project: {
      note: "A project picked: the folder chip names it; its icon, + and the shield share one center line.",
      ready: newTab({ cwd: "/Users/you", startedProject: CWD, projects: [CWD] }),
      snapshot: noChat([], { listedSessions: true }),
      play: ready,
    },
    machine: {
      note: "Remote picked: the strip names the machine beside the folder; the folder icon keeps the column.",
      ready: newTab({ cwd: "/Users/you", startedProject: CWD, projects: [CWD] }),
      snapshot: noChat([], { listedSessions: true, peers: ["devbox"], peerKinds: { devbox: "ssh" } }),
      play: async (ctx) => {
        await ready(ctx);
        await ctx.contextMenu({ selector: '.nt-location .acpmux-location-picker[data-kind="computer"] button' });
        await ctx.click({ role: "menuitem", name: "Machines…" });
        await ctx.waitFor(() => ctx.document.querySelector('.acpmux-env-popover.acpmux-env-machines [role="option"]'));
        await ctx.click({ role: "option", name: /devbox/ });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-env-popover") === null);
        await ready(ctx);
      },
    },
  },
});
