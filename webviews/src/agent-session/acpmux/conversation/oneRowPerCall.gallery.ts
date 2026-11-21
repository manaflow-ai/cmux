// l10n-allow-file: gallery fixtures (sample prompts, paths and file text), not shipped UI.
// One tool call is one row from pending to done in a running turn (turns.ts `codexLiveTurn`, Leo,
// 2026-11-07: "sometimes you can just combine the, like, whatever command or action you're doing
// sooner than you do"). Each call is delivered as Claude Code sends it through acpmux: named as its
// block starts (pending, no input), whole once its input came (running), done, then the next call
// starts and the finished one folds into its run. The `pending`, `running` and `done` variants hold
// one state each; the `play-*` variants run the whole call through the pane's bridge, and the
// experiment (oneRowPerCall.experiment.ts) compares the arms on the Write.
import { agentPaneEntry, type AgentPaneVariant } from "../../../gallery/format";
import { activity, assistant, chat, tool, user } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";
import type { AcpmuxActivity, AcpmuxRow, AcpmuxSnapshot } from "../model";
import { oneRowPerCall } from "./oneRowPerCall.experiment";

type Fields = Partial<NonNullable<AcpmuxActivity["tool"]>>;
type Kind = { title: string; kind: string; running: Fields; done: Fields };

const GEN = "/Users/you/src/fleetviz/gen.py";
const genText = "import json\n\nprint(json.dumps({'ok': True}))\n";
const writeInput = JSON.stringify({ file_path: GEN, content: genText });
const README = "/Users/you/src/fleetviz/README.md";
const editInput = JSON.stringify({
  file_path: README,
  old_string: "# fleetviz",
  new_string: "# fleetviz\n\nRun gen.py.",
});

const KINDS: Record<string, Kind> = {
  write: {
    title: "Write",
    kind: "edit",
    running: { title: "Write gen.py", inputSummary: writeInput },
    done: { title: "Write gen.py", inputSummary: writeInput, diffs: [{ path: GEN, newText: genText }] },
  },
  edit: {
    title: "Edit",
    kind: "edit",
    running: { title: "Edit README.md", inputSummary: editInput },
    done: {
      title: "Edit README.md",
      inputSummary: editInput,
      diffs: [{ path: README, oldText: "# fleetviz\n", newText: "# fleetviz\n\nRun gen.py.\n" }],
    },
  },
  bash: {
    title: "Bash",
    kind: "execute",
    running: { command: "python3 gen.py" },
    done: { command: "python3 gen.py", output: '{"ok": true}\n', exitCode: 0 },
  },
};

const prompt = user("Write a generator for the fleet status page", 2);
const earlier = activity(
  [
    tool("Read README.md", "read", "completed", { locations: [{ path: README }] }),
    tool("Grep status", "search", "completed", { inputSummary: JSON.stringify({ pattern: "status" }) }),
  ],
  1.9,
  { id: "orpc-earlier" },
);
const note = assistant("The status page has no generator yet. Writing one.", 1.8, { id: "orpc-note" });

/** A call's item in one state, its id the same in every state, as the harness keeps it. */
function call(name: string, state: "pending" | "running" | "done"): AcpmuxActivity {
  const spec = KINDS[name]!;
  const fields = state === "pending" ? {} : state === "running" ? spec.running : spec.done;
  const status = state === "pending" ? "pending" : state === "running" ? "in_progress" : "completed";
  const item = tool(spec.title, spec.kind, status, fields);
  return { ...item, tool: { ...item.tool!, id: `orpc-${name}`, startedAt: Date.now() - 12_000 } };
}

const next = (): AcpmuxActivity => {
  const item = tool("Read gen.py", "read", "in_progress", { locations: [{ path: GEN }] });
  return { ...item, tool: { ...item.tool!, id: "orpc-next" } };
};

const turn = (items: AcpmuxActivity[]): AcpmuxSnapshot =>
  chat([prompt, earlier, note, activity(items, 1.7, { id: "orpc-run" }) as AcpmuxRow], { isWorking: true });

/** The call's states in order: pending, running, done, then the next call. */
const phases = (name: string): AcpmuxSnapshot[] => [
  turn([call(name, "pending")]),
  turn([call(name, "running")]),
  turn([call(name, "done")]),
  turn([call(name, "done"), next()]),
];

type Bridge = { receive(snapshot: AcpmuxSnapshot): void };
const bridgeOf = (doc: Document) => {
  const bridge = (doc.defaultView as unknown as { cmuxAcpmuxBridge?: Bridge }).cmuxAcpmuxBridge;
  if (!bridge) throw new Error("the pane bridge is not installed");
  return bridge;
};
const lineText = (doc: Document) => doc.querySelector(".cv-worked--live .cv-thinking")?.textContent ?? "";

/** Delivers phase `index` of `name` and waits for the live line to have drawn it. */
const deliver =
  (name: string, index: number): Play =>
  async (ctx) => {
    const before = lineText(ctx.document);
    bridgeOf(ctx.document).receive(structuredClone(phases(name)[index]!));
    await ctx.waitFor(() => lineText(ctx.document) !== before || index === 0);
  };

/** pending, then running, done and the next call, one delivery a step. */
const playCall =
  (name: string): Play =>
  async (ctx) => {
    for (let index = 1; index < 4; index += 1) await deliver(name, index)(ctx);
  };

const variants: Record<string, AgentPaneVariant> = {};
for (const name of Object.keys(KINDS)) {
  const [pending, running, done] = phases(name);
  variants[`${name}-pending`] = {
    note: `A ${KINDS[name]!.title} named before its input: one live line, no row of its own above it.`,
    snapshot: pending!,
  };
  variants[`${name}-running`] = { note: `The ${KINDS[name]!.title} running: the same line.`, snapshot: running! };
  variants[`${name}-done`] = {
    note: `The ${KINDS[name]!.title} done: the same line holds it until the next step.`,
    snapshot: done!,
  };
  variants[`play-${name}`] = {
    note: `Play: the ${KINDS[name]!.title} pending, running, done, then the next call folds it into its run.`,
    snapshot: pending!,
    play: playCall(name),
  };
}

export default agentPaneEntry({
  id: "agent-pane.one-row-per-call",
  title: "One row per tool call",
  area: "Agent pane",
  height: 420,
  covers: ["agent-session/acpmux/conversation/Thinking.tsx#Thinking", "agent-session/acpmux/rows/ThinkingRow.tsx"],
  variants,
  experiment: {
    definition: oneRowPerCall,
    script: [
      { name: "Write named, no input yet", run: deliver("write", 0) },
      { name: "Write running with its file", run: deliver("write", 1) },
      { name: "Write done", run: deliver("write", 2) },
      { name: "Next call starts", run: deliver("write", 3) },
    ],
  },
});
