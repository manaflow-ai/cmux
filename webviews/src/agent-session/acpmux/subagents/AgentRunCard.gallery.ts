// l10n-allow-file: gallery fixtures (recorded commands with synthetic paths, prompts and replies), not shipped UI.
// A shell call that starts an agent of another family (`codex exec`, `acpmux run`; agentRuns.ts) as
// that agent (subagentFold.ts `reduceRun`), never a long "Command" row: its card where it started
// (AgentRunCard.tsx), its line in the tray above the composer while it runs, and its row in the
// summary card's Subagents list. Every row here is folded from the update shapes Claude Code
// recorded for such calls (a Bash `tool_call` with `rawInput.command`, its `tool_call_update`, and
// acpmux's `background_task_update`), with the paths, prompts and replies made up.
//
// Variants `card-*` are the one that ships. `group` and `line` are the two others it was picked
// over: the run as an ordinary subagent group card, and as the tray's line with one quiet line where
// it ended. `before` is the Command row the call drew before.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, activity, chat, row, session, tool, user } from "../../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../../gallery/clock";
import type { AcpmuxRow } from "../model";
import { SubagentFold } from "./subagentFold";

/// Leo's screenshot's call (2026-10-24): a Codex review run in the background.
const REVIEW =
  'cd ~/Projects/cmux && codex exec --sandbox read-only -m gpt-6-astra -c model_reasoning_effort=xhigh "Codex xhigh re-review of hq#4038 and review of leo-workspace#1023"';
/// A recorded review through reach, its prompt read from a file and its last message written to one.
const REACHED =
  "reach build-box 'cd ~/Projects/cmux && git fetch -q origin pull/24977/head; codex exec --sandbox read-only -m gpt-6-astra -c model_reasoning_effort=xhigh -o ~/.scratch/lane/final.txt - < ~/.scratch/lane/prompt.txt > ~/.scratch/lane/log 2>&1; cat ~/.scratch/lane/final.txt'";
const FAILED = `cd /tmp && perl -e 'alarm 120; exec @ARGV' codex exec -m gpt-6.1-sol --skip-git-repo-check "Reply with OK." 2>&1 | tail -5`;
const ACPMUX =
  'timeout 900 acpmux run -n tray-review -m codex/gpt-6-astra -e xhigh "Review the tray change for regressions"';

const REPLY = [
  "**VERDICT: SHIP** at `67afbfc`.",
  "",
  "- The card reads the session list per card; no timer runs once nothing does.",
  "- `model.ts` grows the estimate to match the reply's three lines.",
  "- Nit: the Raw toggle could say what it opens.",
].join("\n");

type Call = {
  id: string;
  command: string;
  description?: string;
  background?: boolean;
  /// Minutes ago it started, and minutes later it ended (none while it runs).
  started: number;
  ran?: number;
  /// Its output, and whether the call failed.
  output?: string;
  failed?: boolean;
  /// For `acpmux run --parent`, the child acpmux records (acpmux #25019): its harness, model and effort.
  child?: { harness: string; model: string; effort: string };
};

const text = (said: string) => [{ type: "content", content: { type: "text", text: said } }];

/// The rows Claude Code's updates for `calls` fold to, as the pane folds them.
/// Event numbers, unique across variants, so no two variants' rows share an id.
let seq = 10;

function folded(calls: Call[]): AcpmuxRow[] {
  const fold = new SubagentFold();
  fold.harness = "claude";
  const send = (at: number, update: Record<string, unknown>) =>
    fold.reduce({ seq: (seq += 1), at, msg: { params: { update } } }, update);
  for (const call of calls) {
    const at = minutesAgo(call.started);
    send(at, {
      sessionUpdate: "tool_call",
      toolCallId: call.id,
      title: call.command,
      kind: "execute",
      status: "in_progress",
      rawInput: {
        command: call.command,
        ...(call.description && { description: call.description }),
        ...(call.background && { run_in_background: true }),
      },
    });
    const child = call.child;
    const record = (when: number, fields: Record<string, unknown>) =>
      child &&
      fold.reduceChild(
        { seq: (seq += 1), at: when, msg: fields },
        { childSessionId: `child-${call.id}`, shortName: call.id, ...child, ...fields },
      );
    record(at + 300, { event: "started", state: "running" });
    if (call.background)
      send(at + 500, {
        sessionUpdate: "tool_call_update",
        toolCallId: call.id,
        status: "completed",
        content: text(
          `Command running in background with ID: b${call.id}. Output is being written to: /tmp/claude/tasks/b${call.id}.output. You will be notified when it completes.`,
        ),
      });
    if (call.ran === undefined) continue;
    const end = minutesAgo(call.started - call.ran);
    const state = call.failed ? "failed" : "done";
    record(end - 200, { event: "turn_ended", state, result: { state, reply: call.output } });
    if (!call.background)
      send(end, {
        sessionUpdate: "tool_call_update",
        toolCallId: call.id,
        status: call.failed ? "failed" : "completed",
        content: text(call.output ?? ""),
      });
    else {
      send(end, {
        sessionUpdate: "background_task_update",
        toolCallId: call.id,
        command: call.command,
        state: call.failed ? "failed" : "completed",
      });
      // The agent reads the output file once it is told the run ended.
      send(end + 1000, {
        sessionUpdate: "tool_call",
        toolCallId: `${call.id}-read`,
        kind: "read",
        status: "completed",
        rawInput: { file_path: `/tmp/claude/tasks/b${call.id}.output` },
        content: text(call.output ?? ""),
      });
    }
  }
  return fold.takeRows();
}

/// The same runs as Claude's own subagents would be: what variants `group` and `line` draw.
const plain = (rows: AcpmuxRow[]) =>
  rows.map((entry) => ({
    ...entry,
    subagents: entry.subagents?.map(({ command: _command, result: _result, ...agent }) => agent),
  }));

const running = (): Call => ({ id: "review", command: REVIEW, background: true, started: 5.22 });
const done = (): Call[] => [
  {
    id: "reached",
    command: REACHED,
    description: "Codex xhigh review of #24977",
    started: 9,
    ran: 6.4,
    output: `${REPLY}\nShell cwd was reset to /Users/you/src/atlas-web\n`,
  },
  {
    id: "failed",
    command: FAILED,
    started: 2.4,
    ran: 0.3,
    failed: true,
    output: "ERROR: stream disconnected before completion: model at capacity",
  },
  { id: "acpmux", command: ACPMUX, started: 2, ran: 1.6, output: "No regressions: the tray keeps its height." },
];

/// A child of the chat `acpmux run --parent` started: its command names no harness.
const child = (): Call => ({
  id: "fix",
  command: 'acpmux run --parent "$ACPMUX_SESSION" -n fix "Fix the flaky socket test"',
  started: 4,
  ran: 3.1,
  output: "Fixed: the test waits for the socket before it connects, so it no longer races the server.",
  child: { harness: "codex", model: "gpt-6-astra", effort: "xhigh" },
});

const ask = "Get Codex to review #24977 and hq#4038.";
/// The acpmux session `acpmux run -n tray-review` made, as the session list has it.
const reviewChat = session({
  sessionId: "tray-review",
  title: "Review the tray change",
  name: "tray-review",
  harness: "codex",
});
const fixChat = session({ sessionId: "child-fix", title: "Fix the flaky socket test", name: "fix", harness: "codex" });
const withChat = (snapshot: ReturnType<typeof chat>) => ({
  ...snapshot,
  sessions: [...snapshot.sessions, reviewChat, fixChat],
});

export default agentPaneEntry({
  id: "agent-pane.agent-runs",
  title: "Agents a shell call starts",
  area: "Agent pane",
  height: 620,
  covers: ["agent-session/acpmux/subagents/AgentRunCard.tsx"],
  variants: {
    before: {
      note: "Before: the call is a Command row with the raw shell line, and Session Info lists it under Background tasks as `cd ~/Projects/cmux && codex exec …`.",
      snapshot: chat(
        [
          user(ask, 5.4),
          activity(
            [
              tool(REVIEW, "execute", "in_progress", {
                command: REVIEW,
                inputSummary: JSON.stringify({ command: REVIEW, run_in_background: true }),
                startedAt: minutesAgo(5.22),
              }),
            ],
            5.22,
          ),
        ],
        { isWorking: true },
      ),
    },
    "card-running": {
      note: "Shipped: a Codex review running in the background as its card, with the Codex mark, its prompt's first line, gpt-6-astra xhigh, the working spinner and its time; Show output opens the run, Raw the command. The tray above the composer lists it as a Subagent with the same mark.",
      snapshot: chat([user(ask, 5.4), ...folded([running()])], { isWorking: true }),
    },
    "card-done": {
      note: "Shipped: ended runs. A review through reach (the title is the call's description; its prompt came from a file) with its reply as Markdown cut to three lines, a failed one with its error, and an acpmux run whose session the list has, which opens as its chat.",
      snapshot: withChat(
        chat([user(ask, 9.2), ...folded(done()), assistant("Codex says SHIP; the Sol probe failed at capacity.", 0.2)]),
      ),
    },
    "card-child": {
      note: "Shipped: an `acpmux run --parent` call's child as acpmux records it (#25019): its harness, model and effort though the command names none, its reply from its turn's end, and Open chat opens it.",
      snapshot: withChat(chat([user("Have Codex fix the flaky socket test.", 4.2), ...folded([child()])])),
    },
    group: {
      note: "Not picked: the run as an ordinary subagent group card. It says less (no model, no reply) and hides the result one more click away.",
      theme: { subagentTray: false },
      snapshot: chat([user(ask, 9.2), ...plain(folded([running(), ...done()]))], { isWorking: true }),
    },
    line: {
      note: "Not picked: the tray's line while it runs and a quiet one-line end in the transcript. The reply is only in the run's own view.",
      snapshot: chat([user(ask, 9.2), ...plain(folded(done())), row("assistant", 0.2, { text: "Done." })]),
    },
    summary: {
      note: "Session Info's Subagents section: the runs as subagent rows with their harness's mark, Codex · gpt-6-astra xhigh, their state and time; the running review first.",
      snapshot: withChat(chat([user(ask, 9.2), ...folded([running(), ...done()])], { isWorking: true })),
      play: async (ctx) => {
        if (!ctx.document.querySelector(".acpmux-summary-card"))
          await ctx.click({ selector: ".acpmux-summary-button" });
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-summary-card .acpmux-summary-agents"));
        const rows = ctx.document.querySelectorAll(".acpmux-summary-card .acpmux-summary-agents .acpmux-agent-line");
        if (rows.length !== 4) throw new Error(`Session Info lists ${rows.length} runs, expected 4`);
      },
    },
  },
});
