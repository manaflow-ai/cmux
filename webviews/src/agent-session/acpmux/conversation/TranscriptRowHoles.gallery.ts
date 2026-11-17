// l10n-allow-file: gallery fixtures (sample prompts, tool titles and lane messages), not shipped UI.
// No hole between activity rows after a fold (Leo, 2026-11-17: "why is there this big gap when i have
// shit expanded", on an opened "Worked for" whose rows 'Write round 4 script', 'Received 3 messages'
// and 'Used a tool and ran 2 commands' stood ~60px apart, some open, some closed; and "THE F---ING
// SHIFTS EVERY TIME IM SCROLLING"). Every finished turn here folds under "Worked for" and opens to his
// shape: a one-call run line, a "Received 3 messages" row, a "Used a tool and ran 2 commands" run, a
// shell call, more runs, then a reply. Twelve turns, so a turn can be opened while following the
// bottom and while scrolled up mid-history, and its rows scrolled out of the window and back.
// Drawn through the real pane (App.tsx turn shaping, laneNoticeBatches.ts, VirtualTranscript.tsx).
// Test: webviews/test/transcript-row-holes-browser.test.ts.
import { agentPaneEntry, type AgentPaneVariant } from "../../../gallery/format";
import { SESSION_ID, activity, assistant, chat, session, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import type { AcpmuxRow } from "../model";

/// Turns in the chat. The test opens turn `TURNS - 1` (at the bottom) and turn `MIDDLE` (scrolled up).
export const TURNS = 12;
export const MIDDLE = 5;

const SENDERS = [
  { name: "lane-box-1/grid-pitch", session: "s-grid", harness: "claude" },
  { name: "lane-box-3/picker-polish", session: "s-picker", harness: "codex" },
  { name: "lane-box-4/rail-speed", session: "s-rail", harness: "claude" },
];
const TEXT = [
  "Row pitch is 22px on every one-line row now; the PR is up at 9c41a07.\n\nScreenshots are in the PR.",
  "Picker polish is up for review.",
  "Rail scroll is 4ms per frame on the long fixture, down from 19ms.\n\nThe bench is in the PR body.",
];

const lines = (count: number, what: string) =>
  Array.from({ length: count }, (_, index) => `${what} ${index + 1}: ok`).join("\n");

/// Another agent's message that came in while the turn ran (three in a row draw as one
/// "Received 3 messages" row, laneNoticeBatches.ts).
const received = (turn: number, index: number, minutes: number): AcpmuxRow =>
  user("", minutes, {
    id: `t${turn}-msg${index}`,
    continues: true,
    untyped: true,
    incoming: {
      kind: "message",
      message: {
        name: SENDERS[index]!.name,
        sessionId: SENDERS[index]!.session,
        harness: SENDERS[index]!.harness,
        text: TEXT[index]!,
        raw: TEXT[index]!,
      },
    },
  });

const shell = (title: string, command: string, output: string) =>
  tool(title, "execute", "completed", { command, output, exitCode: 0 });

/// One finished turn, Leo's shape. Ids are `t<turn>-<part>`; its "Worked for" line is `worked-t<turn>-user`.
function turn(index: number, minutes: number): AcpmuxRow[] {
  const id = (part: string) => `t${index}-${part}`;
  return [
    user(`Round ${index + 1}: run the script and report what changed`, minutes, { id: id("user") }),
    activity(
      [tool(`Write round ${index + 1} script`, "other", "completed", { output: lines(6, "wrote line") })],
      minutes - 0.1,
      { id: id("write") },
    ),
    received(index, 0, minutes - 0.2),
    received(index, 1, minutes - 0.25),
    received(index, 2, minutes - 0.3),
    activity(
      [
        tool("mcp__memory__search", "other", "completed", { output: lines(4, "memory hit") }),
        shell("Run the round script", `bash round-${index}.sh`, lines(12, "step")),
        shell("Check the output", `rg -n done out-${index}.log`, lines(8, "done")),
      ],
      minutes - 0.4,
      { id: id("used") },
    ),
    assistant("The script ran; checking the log next.", minutes - 0.5, { id: id("note") }),
    activity([shell("Tail the log", `tail -n 30 out-${index}.log`, lines(30, "log line"))], minutes - 0.6, {
      id: id("shell"),
    }),
    assistant("Log is clean. Reading the two configs it touched.", minutes - 0.7, { id: id("mid") }),
    activity(
      [
        tool(`Read config-${index}.toml`, "read", "completed", { output: lines(10, "key") }),
        tool(`Read limits-${index}.toml`, "read", "completed", { output: lines(6, "limit") }),
      ],
      minutes - 0.8,
      { id: id("reads") },
    ),
    assistant(
      `Round ${index + 1} is done.\n\nThe script wrote its output, the log is clean, and both configs hold the new limits. ` +
        "Nothing else changed; the next round can start from this state.",
      minutes - 0.9,
      { id: id("reply") },
    ),
    summary(minutes - 0.95, { id: id("end"), status: "completed", durationMs: 98_000, toolCount: 7 }),
  ];
}

function snapshot() {
  const rows = Array.from({ length: TURNS }, (_, index) => turn(index, 200 - index * 10)).flat();
  return chat(rows, {
    title: "round-runner",
    sessions: [
      session({ sessionId: SESSION_ID, title: "round-runner", name: "round-runner" }),
      ...SENDERS.map((sender) =>
        session({ sessionId: sender.session, title: sender.name, name: sender.name, harness: sender.harness }),
      ),
    ],
  });
}

const variants: Record<string, AgentPaneVariant> = {
  history: {
    note: 'Twelve finished turns, each folded under "Worked for". Opened, a turn shows a one-call run line, "Received 3 messages", "Used a tool and ran 2 commands", a shell call, more runs and a reply, flush on the 22px pitch with no hole between them, whatever is open.',
    snapshot: snapshot(),
  },
};

export default agentPaneEntry({
  id: "agent-pane.transcript-row-holes",
  title: "Transcript: no hole between activity rows",
  area: "Agent pane",
  height: 700,
  widths: { narrow: 520, normal: 760, wide: 1100 },
  covers: [
    "agent-session/acpmux/VirtualTranscript.tsx#VirtualTranscript",
    "agent-session/acpmux/conversation/foldRide.ts",
    "agent-session/acpmux/conversation/turnFold.ts",
  ],
  variants,
});
