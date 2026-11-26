// l10n-allow-file: gallery fixtures (sample prompts, commands and replies), not shipped UI.
// A turn folds under "Worked for" only when the fold hides something worth hiding (turns.ts
// `worthFolding`): three work rows, or five seconds. Smaller turns draw flat, no line and no chevron.
// Leo, 2026-11-24, on a wake's "Report from Subagent" under "Worked for 0s": "honestly in these cases
// should we just... not do our folding situation? this edge case? cuz otherwise it's so weird".
// Test: conversation/workedForSmallTurns.test.tsx.
import { agentPaneEntry, type AgentPaneVariant } from "../../../gallery/format";
import { activity, assistant, chat, summary, thought, tool, user } from "../../../gallery/fixtures/acpmux";
import type { AcpmuxRow } from "../model";

const peer = (name: string, text: string, minutes: number): AcpmuxRow =>
  user(text, minutes, {
    incoming: { kind: "message", message: { name, text, raw: text } },
  } as Partial<AcpmuxRow>);

const stop = (minutes: number) =>
  activity(
    [
      thought("The lane is green.\nNothing left to do but stop the monitor."),
      tool("Stopped the monitor", "execute", "completed", { command: "acpmux bg stop 7f2c", output: "ok\n" }),
    ],
    minutes - 0.01,
  );

const done = (minutes: number, ms: number, toolCount = 1) =>
  summary(minutes - ms / 60_000, { status: "completed", durationMs: ms, toolCount });

const variant = (note: string, rows: AcpmuxRow[]): AgentPaneVariant => ({
  note,
  snapshot: chat(rows, { title: "Small turns", harness: "claude" }),
});

export default agentPaneEntry({
  id: "agent-pane.worked-for-small-turns",
  title: "Worked for: small turns",
  area: "Agent pane",
  height: 420,
  widths: { narrow: 520, normal: 760, wide: 900 },
  covers: ["agent-session/acpmux/conversation/TurnRows.tsx#WorkedFor"],
  variants: {
    "one-wake": variant("One wake row, 0.8 s: flat, no Worked for, no 0s.", [
      user("Watch the lane and tell me when it is green", 10),
      assistant("Watching it.", 9.5),
      done(9.4, 4_000, 0),
      peer("lane-1", "Lane is green.", 3),
      stop(3),
      done(3, 800),
    ]),
    "two-wakes": variant("Two wakes back to back, nothing said between them: one flat run.", [
      user("Watch the lanes and tell me when they are green", 10),
      assistant("Watching them.", 9.5),
      done(9.4, 4_000, 0),
      peer("lane-1", "Lane 1 is green.", 4),
      stop(4),
      done(4, 700),
      peer("lane-2", "Lane 2 is green.", 3),
      stop(3),
      done(3, 900),
    ]),
    "wake-reply": variant("A wake and a one-line reply: the reply under its flat rows.", [
      user("Watch the lane and tell me when it is green", 10),
      assistant("Watching it.", 9.5),
      done(9.4, 4_000, 0),
      peer("lane-1", "Lane is green.", 3),
      stop(3),
      assistant("Lane 1 is green; the monitor is stopped.", 2.95),
      done(2.9, 2_500),
    ]),
    "real-turn": variant("A real 30 s turn still folds under Worked for 30s.", [
      user("Fix the tip icon test and push the new head", 10),
      activity(
        [
          thought("Find the tint first, then the test."),
          tool("Searched for the tint", "execute", "completed", { command: "rg -n 'func applyTint'", output: "ok\n" }),
          tool("Updated the tip icon test", "execute", "completed", { command: "git apply tip.patch", output: "ok\n" }),
          tool("Pushed the new head", "execute", "completed", { command: "git push -q origin HEAD", output: "ok\n" }),
        ],
        9.8,
      ),
      assistant("Pushed the new head; the test now expects the results icon at 83% alpha.", 9.5),
      done(9.5, 30_000, 3),
    ]),
  },
});
