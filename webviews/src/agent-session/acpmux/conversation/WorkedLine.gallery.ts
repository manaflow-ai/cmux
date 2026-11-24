// l10n-allow-file: gallery fixtures (a prompt, commands, paths and the agent's reply), not shipped UI.
// What a closed "Worked for" says (workedLine.experiment.ts). The glance shows the outcome, not the
// steps: the line is the transcript's one look at past work, and today it spends it on a duration.
// Leo, 2026-11-22: "beyer is like... directionally right. Executionally/even in decisions, we cannot
// simply defer to dude everywhere. we need to innovate and expand and pivot and redirect and argue
// against." The arms name what the turn did and how it came out, from the calls the fold holds: no
// model call, one pass over the turn's calls (workedOutcome.ts). `now` is today's line.
// Two turns: one that landed (tests pass, a PR opened) and one that did not (a lint failed, the
// tests failed). The variants replay acpmux's events through the pane's own client
// (fixtures/recording.ts), so they show what the code makes. Synthetic data.
import { agentPaneEntry, type AgentPaneVariant } from "../../../gallery/format";
import { minutesAgo } from "../../../gallery/clock";
import { chat } from "../../../gallery/fixtures/acpmux";

const CHAT = "0190a000-0000-7000-8000-0000000000f7";
const ROOT = "/Users/you/src/atlas-web";

type Step = [string, string, Record<string, unknown>];
type Event = { sessionId: string; seq: number; at: number; dir: string; kind: string; msg: Record<string, unknown> };
const update = (fields: Record<string, unknown>) => ({ method: "session/update", params: { update: fields } });
const say = (text: string): Step => [
  "in",
  "agent_message_chunk",
  update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } }),
];
const text = (body: string) => [{ type: "content", content: { type: "text", text: body } }];
const ran = (id: string, command: string, exit: number, output = ""): Step => [
  "in",
  "tool_call",
  update({
    sessionUpdate: "tool_call",
    toolCallId: id,
    title: command,
    kind: "execute",
    status: exit === 0 ? "completed" : "failed",
    rawInput: { command },
    rawOutput: { exit_code: exit },
    ...(output && { content: text(output) }),
  }),
];
const read = (id: string, file: string): Step => [
  "in",
  "tool_call",
  update({
    sessionUpdate: "tool_call",
    toolCallId: id,
    title: `Read ${file.split("/").at(-1)}`,
    kind: "read",
    status: "completed",
    locations: [{ path: `${ROOT}/${file}` }],
  }),
];
const edit = (id: string, file: string, oldText: string, newText: string): Step => [
  "in",
  "tool_call",
  update({
    sessionUpdate: "tool_call",
    toolCallId: id,
    title: `Edit ${file.split("/").at(-1)}`,
    kind: "edit",
    status: "completed",
    locations: [{ path: `${ROOT}/${file}` }],
    content: [{ type: "diff", path: `${ROOT}/${file}`, oldText, newText }],
  }),
];

/// One turn of `work`, 36 seconds from its prompt to its result.
function turn(id: string, prompt: string, work: Step[], reply: string): Step[] {
  return [
    ["mux", "user_message", { text: prompt, turnId: id }],
    ["mux", "turn_started", { turnId: id }],
    ...work,
    say(reply),
    ["mux", "turn_result", { turnId: id, status: "completed" }],
  ];
}

const landed = turn(
  "t1",
  "Add retries to the fetch helper and open a PR",
  [
    read("r1", "src/net/fetchJson.ts"),
    edit("e1", "src/net/fetchJson.ts", "return fetch(url);\n", "return withRetry(() => fetch(url));\n"),
    edit("e2", "src/net/retry.ts", "", "export async function withRetry() {}\n"),
    ran("c1", "bun test src/net", 1, "1 fail\n  retry.test.ts: backs off twice\n"),
    edit("e3", "src/net/retry.ts", "", "export async function withRetry(run, tries = 3) {}\n"),
    ran("c2", "bun test src/net", 0, "4 pass\n"),
    ran("c3", "git push -u origin retries", 0),
    ran("c4", "gh pr create --fill", 0, "https://github.com/acme/atlas-web/pull/482\n"),
  ],
  "Added `withRetry` with three tries and backoff; the fetch helper uses it. Tests pass. PR #482 is open.",
);

const stuck = turn(
  "t2",
  "Now make the upload helper use it too",
  [
    read("r2", "src/net/upload.ts"),
    edit("e4", "src/net/upload.ts", "return post(url, body);\n", "return withRetry(() => post(url, body));\n"),
    ran("c5", "bunx vp lint src/net", 2, "upload.ts:4 'withRetry' is not defined\n"),
    ran("c6", "bun test src/net", 1, "2 fail\n"),
  ],
  "The upload helper now retries, but two upload tests time out under the backoff. I need to know whether uploads should retry at all.",
);

/// Both turns, each 36 seconds from its prompt to its result.
export function workedLineEvents(): Event[] {
  const events: Event[] = [];
  let at = minutesAgo(30);
  for (const steps of [landed, stuck]) {
    const pitch = 36_000 / (steps.length - 2);
    steps.forEach(([dir, kind, msg], index) => {
      events.push({
        sessionId: CHAT,
        seq: events.length + 1,
        at: Math.round(at + Math.max(0, index - 1) * pitch),
        dir,
        kind,
        msg,
      });
    });
    at += 5 * 60_000;
  }
  return events;
}

const recording = {
  events: async () =>
    `${workedLineEvents()
      .map((event) => JSON.stringify(event))
      .join("\n")}\n`,
  harness: "claude" as const,
};

const variant = (arm: string, note: string): AgentPaneVariant => ({
  note,
  snapshot: chat([]),
  recording,
  experiments: { "worked-line": arm },
});

export default agentPaneEntry({
  id: "agent-pane.worked-line",
  title: "What a closed Worked for says: its time, or what the turn did",
  area: "Agent pane",
  height: 640,
  covers: [
    "agent-session/acpmux/conversation/workedOutcome.ts",
    "agent-session/acpmux/conversation/workedLine.experiment.ts",
    "agent-session/acpmux/conversation/TurnRows.tsx#WorkedLabel",
  ],
  keywords: ["worked", "fold", "outcome", "counts", "failed", "tests", "pr", "beyer"],
  variants: {
    now: variant("time", "Before: Worked for 36s, the time alone."),
    counts: variant("counts", "Counts only: Worked for 36s · 4 commands · 2 files."),
    outcome: variant(
      "outcome",
      "Shipped: counts and outcome, the run's sentence, then failures in the failure red, the tests' result and the PR it opened.",
    ),
    sentence: variant("sentence", "One sentence: what it did, then how it came out, the time last and quieter."),
  },
});
