// l10n-allow-file: gallery fixtures (sample prompts, pull request titles and subagent names), not shipped UI.
// The composer strip (strip/ComposerStrip.tsx, hq#1957, Leo and Lawrence 2026-10-14): the folder,
// the machine, the chat's pull requests and its running subagents in one strip on the composer's
// top edge. Compare arms (`composer-strip`: off, flat, tab, gooey, tray) shows each variant on the
// same chat; the script starts a subagent, then finishes it. Light and dark come from the stage's
// theme controls. test/composer-strip-variants.test.ts measures it.
import { agentPaneEntry } from "../../../gallery/format";
import { minutesAgo } from "../../../gallery/clock";
import { activity, assistant, chat, row, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";
import type { AcpmuxSnapshot } from "../model";
import { SUBAGENTS, type Subagent } from "../subagents/subagentFold";
import { composerStrip } from "./composerStrip.experiment";

const create = (title: string, number: number) =>
  tool(`gh pr create --title "${title}"`, "execute", "completed", {
    command: `gh pr create --title "${title}" --fill`,
    output: `https://github.com/acme/atlas-web/pull/${number}\n`,
    exitCode: 0,
  });

const PRS = [
  create("Add retry to the uploader", 41),
  create("Cover retry with a test", 42),
  create("Document retry", 43),
];

export function stripAgent(name: string, minutes: number, state: Subagent["state"] = "running"): Subagent {
  return {
    id: `agent-${name.toLowerCase().replaceAll(" ", "-")}`,
    parent: null,
    name,
    task: `${name}: read the fetch helper and report`,
    state,
    startedAt: minutesAgo(minutes),
    ...(state !== "running" && { endedAt: minutesAgo(0) }),
  };
}

export const AGENTS = [stripAgent("Retry policy", 3), stripAgent("Error paths", 2), stripAgent("Timeouts", 1)];

/// A running chat that opened `prs` pull requests and runs `agents`.
export function stripChat(
  prs: number,
  agents: readonly Subagent[],
  fields: Partial<AcpmuxSnapshot> = {},
): AcpmuxSnapshot {
  const rows = [
    user("Split the retry change into PRs and audit the fetch helper", 6),
    ...(prs > 0 ? [activity(PRS.slice(0, prs), 5)] : []),
    assistant(prs > 0 ? `Opened ${prs === 1 ? "#41" : "#41 to #43"}.` : "Looking at the fetch helper.", 4),
    ...(agents.length > 0 ? [row(SUBAGENTS, 3, { id: "strip-group", subagents: [...agents] })] : []),
    ...(agents.length === 0 && prs === 0 ? [summary(4, { status: "completed" })] : []),
  ];
  return chat(rows, {
    title: "Composer strip",
    isWorking: agents.some((agent) => agent.state === "running"),
    ...fields,
  });
}

const QUEUE = [
  { id: "q1", prompt: "Then add a test for the 429 path" },
  { id: "q2", prompt: "And update the README" },
];

type Bridge = { receive(snapshot: AcpmuxSnapshot): void };
const deliver = (snapshot: AcpmuxSnapshot) =>
  (window as unknown as { cmuxAcpmuxBridge?: Bridge }).cmuxAcpmuxBridge?.receive(structuredClone(snapshot));

const stripHas =
  (count: number): Play =>
  async (ctx) => {
    await ctx.waitFor(() => ctx.document.querySelectorAll(".acpmux-strip-agent").length === count);
  };

export default agentPaneEntry({
  id: "agent-pane.composer-strip-variants",
  title: "Composer strip: pull requests and subagents",
  area: "Agent pane",
  height: 420,
  widths: { narrow: 420, normal: 720, wide: 1100 },
  anchors: [{ selector: ".acpmux-composer-box" }, { selector: ".acpmux-composer-bar" }],
  covers: [
    "agent-session/acpmux/strip/ComposerStrip.tsx#ComposerStrip",
    "agent-session/acpmux/strip/ComposerStrip.tsx#DockedPullRequests",
    "agent-session/acpmux/strip/StripPullRequests.tsx#StripPullRequests",
    "agent-session/acpmux/strip/StripSubagents.tsx#StripSubagents",
  ],
  experiment: {
    definition: composerStrip,
    script: [
      {
        name: "a subagent starts",
        run: async (ctx) => {
          deliver(stripChat(1, AGENTS.slice(0, 2)));
          await stripHas(2)(ctx);
        },
      },
      {
        name: "it finishes and leaves",
        run: async (ctx) => {
          deliver(stripChat(1, [AGENTS[0]!, stripAgent("Error paths", 2, "completed")]));
          await stripHas(1)(ctx);
        },
      },
    ],
  },
  variants: {
    context: { note: "Folder and machine only: no pull request, no subagent.", snapshot: stripChat(0, []) },
    "one-pr": { note: "The chat opened one pull request: its chip after the machine.", snapshot: stripChat(1, []) },
    "three-prs": {
      note: "Three pull requests: the newest, then +2, which lists them all with their dismiss buttons.",
      snapshot: stripChat(3, []),
    },
    "one-agent": {
      note: "One pull request and one running subagent: its name, glyph and time.",
      snapshot: stripChat(1, AGENTS.slice(0, 1)),
    },
    "three-agents": {
      note: "Three running subagents collapse to one chip naming how many; its popover lists them.",
      snapshot: stripChat(1, AGENTS),
    },
    queued: {
      note: "Queued prompts keep their own slot above the strip.",
      snapshot: { ...stripChat(3, AGENTS.slice(0, 1)), queue: QUEUE },
    },
  },
});
