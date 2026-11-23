// l10n-allow-file: gallery fixtures, not shipped UI.
//
// Door A end to end (MachineJoinFlow.tsx): the composer strip and the line under it over the page's
// real join store, with a scripted acpmux. The plays click through what a person does.
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";

const openRemote: Play = async (ctx) => {
  await ctx.click({ role: "button", name: /^Environment/ });
  await ctx.waitFor(() => ctx.document.querySelector('.acpmux-env-popover.acpmux-env-rows-where [role="option"]'));
  await ctx.click({ selector: '.acpmux-env-popover [data-action="another"]' });
  await ctx.waitFor(() => ctx.document.querySelector('.acpmux-env-popover [data-action="join"]'));
};
const line = (ctx: Parameters<Play>[0]) => ctx.document.querySelector('[data-testid="machine-join-line"]');

export default componentEntry({
  id: "agent-pane.machine-join-flow",
  title: "Machine join, end to end",
  area: "Agent pane",
  pane: true,
  covers: ["agent-session/acpmux/MachineJoinFlow.tsx#MachineJoinFlow"],
  styles: () =>
    Promise.all([import("./styles.css"), import("./composerLocation.css"), import("./machineJoinLine.css")]),
  load: () => import("./MachineJoinFlow").then((module) => module.MachineJoinFlow),
  widths: { narrow: 400, normal: 620, wide: 760 },
  height: 420,
  variants: {
    start: {
      note: "The new chat on This Mac, before any click; the recorded click-through starts here.",
      props: {},
    },
    "own-node": {
      note: "Where > Remote, then one click on gcp-3 (the person's own tailnet node): no question, the strip names it as being set up and the line counts through its steps.",
      props: {},
      play: async (ctx) => {
        await openRemote(ctx);
        await ctx.click({ selector: '.acpmux-env-popover [data-action="join"][data-mine]' });
        await ctx.waitFor(() => line(ctx)?.textContent?.includes("installing"));
      },
    },
    "other-host": {
      note: "A host that is not the person's own asks once, naming host and login; Add runs it, and a refused key says its next step with Try Again.",
      props: {},
      play: async (ctx) => {
        await openRemote(ctx);
        await ctx.click({ selector: '.acpmux-env-popover [data-action="joinOther"]' });
        await ctx.waitFor(() =>
          ctx.document.querySelector('.acpmux-env-popover [data-action="join"]:not([data-mine])'),
        );
        await ctx.click({ selector: '.acpmux-env-popover [data-action="join"]:not([data-mine])' });
        await ctx.waitFor(() => line(ctx)?.getAttribute("data-phase") === "confirm");
        await ctx.click({ selector: ".acpmux-join-action[data-primary]" });
        await ctx.waitFor(() => line(ctx)?.getAttribute("data-phase") === "failed");
      },
    },
  },
});
