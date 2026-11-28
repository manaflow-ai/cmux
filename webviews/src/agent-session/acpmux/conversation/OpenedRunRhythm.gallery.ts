// l10n-allow-file: gallery fixtures (sample lane names, messages and commands), not shipped UI.
// An opened message run in a turn the agent ran on its own. Leo, 2026-11-17: "why is there this big
// gap when i have s**t expanded", on "Ran 3 commands, used a tool, received 3 messages" opened: an
// empty band of about 32 px over "Write round 4 script ›", "Received 3 messages" flush under it,
// another band over "Used a tool and ran 2 commands ›", then the next message flush. A background
// task's end woke the agent; the rows its events made carry that turn (direct.ts `inBackground`),
// but another agent's message steered into it is a user row and never does. Each tool row under
// such a line took the gap that opens a background turn (model.ts `opensBackgroundTurn`, the 32 px
// turn gap), inside one run. The variants replay acpmux's events through the pane's own client
// (fixtures/recording.ts), so they show what the code makes. test/opened-run-rhythm-browser.test.ts
// opens the run and measures every row it reveals. Synthetic data.
import { agentPaneEntry } from "../../../gallery/format";
import { minutesAgo } from "../../../gallery/clock";
import { chat } from "../../../gallery/fixtures/acpmux";

const CHAT = "0190a000-0000-7000-8000-0000000000fa";

type Step = [string, string, Record<string, unknown>];
const update = (fields: Record<string, unknown>) => ({ method: "session/update", params: { update: fields } });
const say = (text: string): Step => [
  "in",
  "agent_message_chunk",
  update({ sessionUpdate: "agent_message_chunk", content: { type: "text", text } }),
];
const call = (id: string, title: string, kind: string, rawInput?: Record<string, unknown>): Step => [
  "in",
  "tool_call",
  update({ sessionUpdate: "tool_call", toolCallId: id, title, kind, status: "completed", rawInput }),
];
/// Another agent's message, delivered into the running turn.
const message = (index: number, fromName: string, text: string): Step => [
  "mux",
  "user_message",
  {
    text,
    steer: true,
    promptId: `rhythm-msg-${index}`,
    _meta: { provenance: { kind: "agent_message", from: "cli", fromName, msgId: `rhythm-m-${index}` } },
  },
];

/// The person's turn that started a background wait, then the turn the wait's end woke: a command,
/// three messages in, a read and two commands, one more message. `ended` adds the woken turn's end.
export function openedRunEvents(ended: boolean) {
  const steps: Step[] = [
    ["mux", "user_message", { text: "Run the round 4 check once the mirror catches up", turnId: "t1" }],
    ["mux", "turn_started", { turnId: "t1" }],
    call("wait", "Wait for the mirror", "execute", { command: "mirror-wait --timeout 900", run_in_background: true }),
    say("Waiting for the mirror before round 4."),
    ["mux", "turn_result", { turnId: "t1", status: "completed" }],
    [
      "mux",
      "background_turn",
      {
        state: "started",
        id: "bg-round4",
        trigger: "task_notification",
        cause: {
          kind: "shell",
          status: "completed",
          weight: "result",
          origin: "wait",
          summary: 'Background command "Wait for the mirror" completed (exit code 0)',
        },
      },
    ],
    call("script", "Write round 4 script", "execute", { command: "cat > /tmp/round4.sh" }),
    message(1, "mirror-stale-commit-graph", "Round 3 gave no verdict: rev-list ran past 600 s."),
    message(2, "mirror-stale-commit-graph", "Mirror refetched; the graph is current."),
    message(3, "mirror-stale-commit-graph", "Ready for round 4."),
    call("read", "Read /tmp/round4.sh", "read", { file_path: "/tmp/round4.sh" }),
    call("run", "Run round 4", "execute", { command: "bash /tmp/round4.sh" }),
    call("verdict", "Check the verdict", "execute", { command: "cat /tmp/round4.out" }),
    message(4, "fleet-capacity-routing", "I've taken the runner revert."),
    say("Round 4 passed: the mirror's graph is current."),
    ...(ended
      ? [
          [
            "mux",
            "background_turn",
            { state: "ended", id: "bg-round4", trigger: "task_notification", quiet: false },
          ] as Step,
        ]
      : []),
  ];
  const start = minutesAgo(20);
  return steps.map(([dir, kind, msg], index) => ({
    sessionId: CHAT,
    seq: index + 1,
    at: start + index * 6_000,
    dir,
    kind,
    msg,
  }));
}

const recording = (ended: boolean) => ({
  events: async () =>
    `${openedRunEvents(ended)
      .map((event) => JSON.stringify(event))
      .join("\n")}\n`,
  harness: "claude" as const,
});

export default agentPaneEntry({
  id: "agent-pane.opened-run-rhythm",
  title: "An opened message run in a turn the agent ran on its own",
  area: "Agent pane",
  height: 520,
  covers: ["agent-session/acpmux/model.ts#opensBackgroundTurn", "agent-session/acpmux/transcriptGrid.ts#transcriptGap"],
  variants: {
    running: {
      note: "The woken turn still runs. Open the message run: every row it reveals sits one 22 px row under the one above.",
      snapshot: chat([], { isWorking: true }),
      recording: recording(false),
    },
    ended: {
      note: "The woken turn ended: its rows draw where they ran, each call on its own row, in the same 22 px rhythm.",
      snapshot: chat([]),
      recording: recording(true),
    },
  },
});
