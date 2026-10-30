// l10n-allow-file: gallery fixtures (sample prompts, subagent names and replies), not shipped UI.
// The composer through a chat's first running turn (hq#1957): idle before the agent has reported
// any context usage, then running while its subagents start (one, then three), a subagent's
// permission ask above the composer, a prompt queued behind the turn, and the turn finished. Each phase is a
// variant; `cycle` starts idle and its play delivers the phases in order through the pane's
// bridge, as the app's snapshots arrive. Nothing in the composer moves across the cycle: the
// prompt, the controls row and each control keep their boxes, and the queued prompt grows upward
// from the card's top edge (test/composer-turn-cycle.test.ts measures it).
import { agentPaneEntry } from "../../gallery/format";
import { assistant, chat, row, summary, user } from "../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../gallery/clock";
import type { Play } from "../../gallery/play";
import type { AcpmuxSnapshot } from "./model";
import { SUBAGENTS, type Subagent } from "./subagents/subagentFold";

const prompt = "Audit the fetch helper: retries, errors and timeouts";

function agent(name: string, state: Subagent["state"] = "running"): Subagent {
  return {
    id: `agent-${name.toLowerCase().replaceAll(" ", "-")}`,
    parent: null,
    name,
    task: name,
    state,
    startedAt: minutesAgo(1),
    ...(state !== "running" && { endedAt: minutesAgo(0.5) }),
  };
}

const effort = {
  id: "effort",
  name: "Reasoning",
  category: "thought_level",
  currentValue: "medium",
  options: [
    { value: "low", name: "Low" },
    { value: "medium", name: "Medium" },
    { value: "high", name: "High" },
  ],
};
const modes = {
  currentModeId: "auto",
  availableModes: [
    { id: "ask", name: "Supervised", description: "Ask before changing files or running commands" },
    { id: "auto", name: "Auto", description: "Choose the safest approval level for each action" },
  ],
};

/** A phase of the turn: the chat's rows, whether it runs, its queue and its context usage (none
 * until the agent reports it, as on a chat's first turn). */
function phase(
  rows: Parameters<typeof chat>[0],
  fields: Partial<Pick<AcpmuxSnapshot, "permission" | "queue">> & { working?: boolean; used?: number } = {},
): AcpmuxSnapshot {
  const { working = false, used, queue = [], ...rest } = fields;
  const snapshot = chat(rows, { title: "Turn cycle", isWorking: working, queue, ...rest });
  const { usage: _usage, ...summary } = snapshot.summary!;
  return {
    ...snapshot,
    summary: {
      ...summary,
      turnCount: 1,
      // Claude Code steers (acpmux `steering`): a prompt typed mid-turn draws the ↵ control.
      steering: true,
      configOptions: [effort],
      modes,
      ...(used === undefined ? {} : { usage: { used, size: 200_000 } }),
    },
  };
}

const group = (agents: Subagent[]) => row(SUBAGENTS, 0.9, { id: "cycle-group", subagents: agents });
const asked = {
  permissionId: "cycle-permission",
  title: "Run bun test src/net",
  pending: true,
  options: [
    { id: "allow_once", name: "Allow", kind: "allow_once", allow: true },
    { id: "allow_chat", name: "Allow for this chat", kind: "allow_chat", allow: true },
    { id: "deny", name: "Reject", kind: "deny", allow: false },
  ],
};
const asking = user(prompt, 1);
const three = [agent("Retry policy"), agent("Error parsing"), agent("Timeouts")];

/** The cycle's phases in order. */
export const TURN_CYCLE: { name: string; snapshot: AcpmuxSnapshot }[] = [
  { name: "idle", snapshot: phase([]) },
  { name: "running", snapshot: phase([asking], { working: true }) },
  { name: "subagents-one", snapshot: phase([asking, group([agent("Retry policy")])], { working: true, used: 21_000 }) },
  { name: "subagents-three", snapshot: phase([asking, group(three)], { working: true, used: 64_500 }) },
  {
    name: "asking",
    snapshot: phase([asking, group(three), row("permission", 0.5, { permission: asked })], {
      working: true,
      used: 71_000,
      permission: asked,
    }),
  },
  {
    name: "queued",
    snapshot: phase([asking, group([agent("Retry policy", "completed"), ...three.slice(1)])], {
      working: true,
      used: 98_000,
      queue: [{ id: "q1", prompt: "Then add a test for the 429 path" }],
    }),
  },
  {
    name: "finished",
    snapshot: phase(
      [
        asking,
        group(three.map((one) => ({ ...one, state: "completed", endedAt: minutesAgo(0.4) }))),
        assistant("All three areas are covered; two timeouts are too short.", 0.2),
        summary(0.2, { status: "completed", durationMs: 64_000 }),
      ],
      { used: 112_250 },
    ),
  },
];

type Bridge = { receive(snapshot: AcpmuxSnapshot): void };

/** Delivers each phase after the first through the pane's bridge, a frame apart. */
const cycle: Play = async (ctx) => {
  const bridge = (ctx.document.defaultView as unknown as { cmuxAcpmuxBridge?: Bridge }).cmuxAcpmuxBridge;
  if (!bridge) throw new Error("the pane bridge is not installed");
  for (const { snapshot } of TURN_CYCLE.slice(1)) {
    bridge.receive(structuredClone(snapshot));
    // Stop while the turn runs; once it ends Stop goes, and with no draft no Send takes its place.
    await ctx.waitFor(() => Boolean(ctx.document.querySelector(".acpmux-cancel")) === Boolean(snapshot.isWorking));
  }
};

export default agentPaneEntry({
  id: "agent-pane.composer-turn-cycle",
  title: "Composer through a running turn",
  area: "Agent pane",
  height: 520,
  widths: { narrow: 420, normal: 720, wide: 1100 },
  anchors: [
    { selector: ".acpmux-composer-box" },
    { selector: ".acpmux-composer-prompt" },
    { selector: ".acpmux-composer-bar" },
  ],
  covers: [
    "agent-session/acpmux/Composer.tsx#Composer",
    "agent-session/acpmux/ComposerQueue.tsx#ComposerQueue",
    "agent-session/acpmux/subagents/SubagentGroup.tsx",
  ],
  variants: {
    ...Object.fromEntries(
      TURN_CYCLE.map(({ name, snapshot }) => [name, { note: `The turn cycle's ${name} phase.`, snapshot }]),
    ),
    cycle: {
      note: "Play: idle, running, one then three subagents, a queued prompt, finished; the composer stays put.",
      snapshot: TURN_CYCLE[0]!.snapshot,
      play: cycle,
    },
  },
});
