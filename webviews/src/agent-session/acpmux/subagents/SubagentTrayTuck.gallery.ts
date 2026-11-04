// l10n-allow-file: gallery fixtures (prompts, subagent tasks and replies), not shipped UI.
// The running tray tucked away behind its grabber (TrayGrabber.tsx). Leo, 2026-11-04: "Some people
// might want to tuck away the composer hat ... what if you wanted to collapse that one line? ... at
// the top of the hat, there's some sort of little thing that's like, I don't know, like a special
// kind of chevron ... you can hover around that, the top of the composer, and then you can click that
// to like unleash the hat". Then, on where it sits: "I also wonder if we'd want the
// grabber/dogear/whatever design thing on maybe the left… or the right…": compare the arms
// (trayGrabber.experiment.ts) in the compare view.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, row, tool, user } from "../../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../../gallery/clock";
import type { PlayContext } from "../../../gallery/play";
import { SUBAGENTS, type Subagent } from "./subagentFold";
import { trayGrabberLook } from "./trayGrabber.experiment";

const TUCKED = { "agentPane.display.trayTucked": true };

const agent = (slug: string, task: string, minutes: number, fields: Partial<Subagent> = {}): Subagent => ({
  id: `agent-${slug}`,
  parent: null,
  name: "general-purpose",
  task,
  kind: "general-purpose",
  state: "running",
  background: true,
  startedAt: minutesAgo(minutes),
  ...fields,
});

const CACHE = agent("cache", "Measure the build cache", 6, { action: "Read warm-sources.json" });
const SIGNING = agent("signing", "Time the signing step", 5, { action: "Running gh run view 81234" });
const PUBLISH = agent("publish", "Check the publish step", 4, { action: "Read publish.yml" });

const scene = (agents: Subagent[]) =>
  chat(
    [
      user("Audit the nightly pipeline end to end, in parallel.", 7),
      assistant("I'll run three agents at once: the cache, signing and publish.", 6.8),
      row(SUBAGENTS, 6, { subagents: agents }),
    ],
    { isWorking: true },
  );

const RUNNING = scene([CACHE, SIGNING, PUBLISH]);

/** The publish agent asks to read a file: the tucked grabber draws its dot. */
const WAITING = {
  ...RUNNING,
  subagentViews: {
    [PUBLISH.id]: [
      activity([tool("Read publish.yml", "read", "in_progress")], 3.9, { id: `${PUBLISH.id}:activity-1` }),
    ],
  },
};
const waitingScene = {
  ...WAITING,
  permission: {
    permissionId: "perm-publish",
    toolCallId: WAITING.subagentViews[PUBLISH.id]![0]!.items![0]!.tool!.id,
    title: "Read publish.yml",
    kind: "read",
    pending: true,
    options: [
      { id: "allow", name: "Allow", allow: true },
      { id: "reject", name: "Reject", allow: false },
    ],
  },
};

const grabber = (ctx: PlayContext) => ctx.document.querySelector<HTMLElement>(".acpmux-tray-grabber");

/** Tucked: no tray lines, only the grabber on the composer's top edge. */
const tucked = async (ctx: PlayContext) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-tray-tucked .acpmux-tray-grabber"));
  if (ctx.document.querySelector(".acpmux-running-tray")) throw new Error("a tucked tray draws no lines");
};

/** Hovers the grabber's band, where the pill is drawn. */
const hovered = async (ctx: PlayContext) => {
  await ctx.waitFor(() => grabber(ctx));
  await ctx.hover({ selector: ".acpmux-tray-grabber" });
};

export default agentPaneEntry({
  id: "agent-pane.subagent-tray-tuck",
  title: "Running tray tucked away",
  area: "Agent pane",
  height: 560,
  widths: { narrow: 360 },
  anchors: [{ selector: ".acpmux-header" }],
  covers: [
    "agent-session/acpmux/subagents/TrayGrabber.tsx",
    "agent-session/acpmux/subagents/trayGrabber.experiment.ts",
  ],
  keywords: ["tuck", "hide", "hat", "composer hat", "grabber", "chevron", "running tray"],
  experiment: {
    definition: trayGrabberLook,
    script: [
      { name: "the tray, its grabber hovered", run: hovered },
      { name: "tucked", run: async (ctx) => ctx.click({ selector: ".acpmux-tray-grabber" }) },
      { name: "back, folded", run: async (ctx) => ctx.click({ selector: ".acpmux-tray-grabber" }) },
    ],
  },
  variants: {
    "shown-hover": {
      note: "The tray shows, folded to its header; the pointer at its top edge draws the grabber, whose click tucks it away.",
      play: hovered,
      snapshot: RUNNING,
    },
    tucked: {
      note: "Tucked (Settings > Tuck Away Running Tray, the palette, the CLI or the grabber): only the grabber on the composer's top edge, drawn while work runs, with how many things run.",
      display: TUCKED,
      play: tucked,
      snapshot: RUNNING,
    },
    "tucked-waiting": {
      note: "Tucked while an agent waits on the person: the grabber draws a dot. Tucking hides noise, never a question.",
      display: TUCKED,
      play: async (ctx) => {
        await tucked(ctx);
        await ctx.waitFor(() => grabber(ctx)?.hasAttribute("data-waiting"));
      },
      snapshot: waitingScene,
    },
    "tucked-hover": {
      note: "Tucked, the pointer on the grabber: a click brings the tray back folded, an Option-click brings it back open.",
      display: TUCKED,
      play: async (ctx) => {
        await tucked(ctx);
        await hovered(ctx);
      },
      snapshot: RUNNING,
    },
  },
});
