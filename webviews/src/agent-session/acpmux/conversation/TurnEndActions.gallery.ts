// l10n-allow-file: gallery fixtures (sample prompts, commands and replies), not shipped UI.
// Every ended turn ends on its row of actions (Copy, Fork, Timeline, More), whatever its last rows
// are (turns.ts `backgroundFooters`, turnEndActions.experiment.ts). Leo, 2026-11-21, on a chat whose
// last rows were a background task's end and the calls the agent ran after it, with no reply: "there's
// no buttons at the bottom even thuogh you have visibly stopped doing things".
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, row, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import type { AcpmuxRow } from "../model";
import { BACKGROUND_TURN, backgroundTurnRowId } from "./backgroundTurns";
import { turnEndActions } from "./turnEndActions.experiment";

/// A turn a background task's end woke, that acpmux called quiet (no reply to tell).
const woke = (id: string, minutes: number, summary: string, extra: Partial<AcpmuxRow["background"]> = {}): AcpmuxRow =>
  row(BACKGROUND_TURN, minutes, {
    id: backgroundTurnRowId(id),
    background: {
      id,
      trigger: "task_notification",
      running: false,
      quiet: true,
      hasRows: true,
      cause: { kind: "shell", status: "completed", weight: "result", summary },
      ...extra,
    },
  });
const ran = (id: string, minutes: number, commands: string[]) =>
  activity(
    commands.map((command) => tool(command, "execute", "completed", { command, output: "ok" })),
    minutes,
    { id: `${id}-calls`, inBackground: id },
  );

const opening = [
  user("Run the identity setup script on the build pool and tell the deputy how it went", 14),
  activity([tool("iam.sh --apply", "execute", "completed", { command: "iam.sh --apply" })], 13.9),
  assistant(
    "I'm running the identity setup script, `iam.sh --apply`, in the background. When it finishes, I'll send the deputy the host, the account it ran as, and the result.",
    13.8,
  ),
  summary(13.8, { status: "completed", durationMs: 12_000, toolCount: 1, seq: 40 }),
];

/// Leo's chat: the task's end woke two turns of calls and a sent message, neither with a reply.
const leos = [
  ...opening,
  woke("gallery-end-a", 10, "Background task finished: run pool iam.sh --apply (WIF providers)"),
  ran("gallery-end-a", 9.9, ["lane-gh send coord-deputy-3 -", "tail -n 40 iam.log", "gcloud iam list"]),
  woke("gallery-end-b", 9, "Background task finished: tail iam.log"),
  ran("gallery-end-b", 8.9, ["tail -n 5 iam.log", "lane-gh send gcp-codex-lane-10/coord-deputy-3 -"]),
];

/// One such turn alone after the answer.
const one = [
  ...opening,
  woke("gallery-one", 10, "Background task finished: run pool iam.sh --apply"),
  ran("gallery-one", 9.9, ["tail -n 40 iam.log", "lane-gh send coord-deputy-3 -"]),
];

/// A woken turn that answered (it had its row before), then one of calls alone.
const answeredThenCalls = [
  ...opening,
  row(BACKGROUND_TURN, 10, {
    id: backgroundTurnRowId("gallery-said"),
    background: { id: "gallery-said", trigger: "task_notification", running: false, quiet: false, hasRows: true },
  }),
  ran("gallery-said", 9.9, ["tail -n 40 iam.log"]),
  assistant("The setup script failed: the deleted links still answered a lookup. I told the deputy.", 9.8, {
    inBackground: "gallery-said",
  }),
  woke("gallery-after", 9, "Background task finished: retry iam.sh --apply"),
  ran("gallery-after", 8.9, ["tail -n 5 iam.log"]),
];

/// The last turn still runs: no row yet, its live line instead.
const running = [
  ...opening,
  woke("gallery-run", 10, "Background task finished: run pool iam.sh --apply", { running: true, quiet: undefined }),
  ran("gallery-run", 9.9, ["tail -n 40 iam.log"]),
];

export default agentPaneEntry({
  id: "agent-pane.turn-end-actions",
  title: "Turn end actions",
  area: "Agent pane",
  height: 520,
  covers: ["agent-session/acpmux/conversation/turns.ts", "agent-session/acpmux/conversation/turnCopy.ts"],
  variants: {
    "leos-chat": {
      note: "Leo's chat, 2026-11-21: a background task's end woke two turns that ran calls and sent a message, with no reply after them. Each ends on its row (Copy, Fork, Timeline, More), and the chat's last rows end on one.",
      snapshot: chat(leos),
    },
    "one-turn": {
      note: "One woken turn of calls alone after the answer: it ends on its own row under its calls.",
      snapshot: chat(one),
    },
    "answered-then-calls": {
      note: "A woken turn that answered keeps its row under its reply, as before; the next one, calls alone, ends on its own.",
      snapshot: chat(answeredThenCalls),
    },
    running: {
      note: "The last turn still runs: it has no row yet, and the live line stays below its calls.",
      snapshot: chat(running, { isWorking: true }),
    },
  },
  // Compare arms: every ended turn (default), only the chat's last, and the reply-only look before.
  experiment: {
    definition: turnEndActions,
    script: [{ name: "rest", run: async () => {} }],
  },
});
