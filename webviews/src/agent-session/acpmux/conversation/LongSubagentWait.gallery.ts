// l10n-allow-file: gallery fixtures (sample prompts, replies and subagent tasks), not shipped UI.
// A long turn that spends almost all of its time waiting on its foreground subagents (Leo,
// 2026-11-03: "i think the "thinking" accounting is also off pretty frequently", on a 1.5 h turn
// whose live line read "Thinking 1h 24m 7s"). The live line names what the turn does now (Thinking.tsx,
// turns.ts `codexLiveTurn`): "Waiting on 3 subagents", a finished step with its own time, or
// "Writing", and past the first step the turn's clock follows a step's own time after a dot.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, row, tool, user } from "../../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../../gallery/clock";
import { SUBAGENTS, type Subagent } from "../subagents/subagentFold";

/// The turn started 1h 24m 7s before the gallery's now.
const TURN = 84 + 7 / 60;

const agent = (id: string, name: string, minutes: number, fields: Partial<Subagent> = {}): Subagent => ({
  id,
  parent: null,
  name,
  kind: "general-purpose",
  state: "running",
  startedAt: minutesAgo(minutes),
  ...fields,
});

const prompt = () => user("Audit the nightly pipeline end to end and fix what is slow", TURN);
const plan = () =>
  assistant("I'll split this three ways: the build cache, the signing step and the publish step.", TURN - 0.5);

export default agentPaneEntry({
  id: "agent-pane.long-subagent-wait",
  title: "Live line: long subagent wait",
  area: "Agent pane",
  height: 360,
  covers: ["agent-session/acpmux/conversation/Thinking.tsx#Thinking"],
  variants: {
    "waiting-on-subagents": {
      note: "Three foreground subagents still run: the line reads Waiting on 3 subagents, and its clock is the turn's whole time, never a 1h 24m think.",
      snapshot: chat(
        [
          prompt(),
          plan(),
          row(SUBAGENTS, TURN - 1, {
            subagents: [
              agent("sa-cache", "Measure the build cache", TURN - 1, { action: "Read warm-sources.json" }),
              agent("sa-sign", "Time the signing step", TURN - 1, { action: "Grep notarize" }),
              agent("sa-publish", "Check the publish step", TURN - 1, { action: "Bash gh run list" }),
            ],
          }),
        ],
        { isWorking: true },
      ),
    },
    "finished-step": {
      note: "Between steps the line holds the last finished step with its own time (3m 27s), then the turn's clock after a dot.",
      snapshot: chat(
        [
          prompt(),
          plan(),
          activity(
            [
              tool("Opened 1 agent session", "other", "completed", {
                startedAt: minutesAgo(5),
                endedAt: minutesAgo(5) + 207_000,
              }),
            ],
            5,
          ),
        ],
        { isWorking: true },
      ),
    },
    thinking: {
      note: "Past the first step with nothing streaming and no own time: Thinking 1h 24m 7s, the turn's clock beside the word, no dot and no word total (#34866).",
      snapshot: chat(
        [
          prompt(),
          activity([tool("git log --oneline -5", "execute", "completed", { command: "git log --oneline -5" })], 3),
          assistant("The signing step waits on a single runner.", 2),
        ],
        { isWorking: true },
      ),
    },
    "ran-command": {
      note: "A command that just finished: its own 0s on its words, then the turn's clock after the dot, 4px each side and one dim tone, as in Leo's capture of the running-step line (2026-11-03: \"same here it's annoying to look at\").",
      snapshot: chat(
        [
          prompt(),
          plan(),
          activity(
            [
              tool("cat /tmp/copy/message.md | head -30", "execute", "completed", {
                command: "cat /tmp/copy/message.md | head -30",
                startedAt: minutesAgo(0.2),
                endedAt: minutesAgo(0.2) + 300,
              }),
            ],
            0.2,
          ),
        ],
        { isWorking: true },
      ),
    },
    writing: {
      note: "The reply paused mid-stream a moment ago: Writing, with the turn's clock. (One that paused past 5 s reads Thinking again.)",
      snapshot: chat(
        [
          prompt(),
          activity([tool("git log --oneline -5", "execute", "completed", { command: "git log --oneline -5" })], 2),
          assistant("The signing step waits on a single runner because", 0),
        ],
        { isWorking: true },
      ),
    },
  },
});
