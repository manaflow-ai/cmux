// l10n-allow-file: gallery fixtures (sample prompts, replies and commands), not shipped UI.
// A steer the agent has not read says so at rest, with the step it waits behind in the live line's
// words, until the agent reads it (Leo, 2026-11-12: "They have tons of helpers and they're not really
// responding to my messages. I'm not sure if they're reading them at all.").
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, row, tool, user } from "../../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../../gallery/clock";
import { SUBAGENTS, type Subagent } from "../subagents/subagentFold";

const STEER = "Are you reading my messages? Answer me first";
const claude = (state: ReturnType<typeof chat>) => ({
  ...state,
  summary: { ...state.summary!, harness: "claude-sr2", family: "claude-sr2", steering: true, backgroundsWork: true },
});
const prompt = () => user("Land the timer, the checklist pill and the link chip", 40);
const steer = (minutes = 1) => user(STEER, minutes, { steer: "waiting", steerPromptId: "p-not-read" });
const helper = (id: string, name: string): Subagent => ({
  id,
  parent: null,
  name,
  kind: "general-purpose",
  state: "running",
  startedAt: minutesAgo(30),
});
const command = (text: string) =>
  activity([tool(text, "execute", "in_progress", { command: text, startedAt: minutesAgo(20) })], 20);

export default agentPaneEntry({
  id: "agent-pane.steer-not-read",
  title: "Steer: not read yet",
  area: "Agent pane",
  height: 360,
  covers: ["agent-session/acpmux/conversation/PendingSteer.tsx#PendingSteer"],
  variants: {
    "behind-a-command": {
      note: "The agent waits on a long command: the steer reads Not read yet · Running glaeda-gh wait pr 42 …, Send now beside it.",
      snapshot: claude(
        chat([prompt(), assistant("Waiting on CI.", 21), command("glaeda-gh wait pr 42 --timeout 3600"), steer()], {
          isWorking: true,
        }),
      ),
    },
    "behind-subagents": {
      note: "The agent waits on its foreground helpers: Not read yet · Waiting on 3 subagents.",
      snapshot: claude(
        chat(
          [
            prompt(),
            assistant("Three helpers are on it.", 35),
            row(SUBAGENTS, 30, {
              subagents: [
                helper("sa-timer", "Fix the turn timer"),
                helper("sa-pill", "Fix the checklist pill"),
                helper("sa-chip", "Fix the pasted-link chip"),
              ],
            }),
            steer(),
          ],
          { isWorking: true },
        ),
      ),
    },
    "long-command-cut": {
      note: "A long command is cut at the row's edge, never widening it; the whole step is in the tooltip.",
      snapshot: claude(
        chat(
          [
            prompt(),
            command(
              "cmux-ci test -- bun test src/agent-session/acpmux/conversation src/agent-session/acpmux/rows --timeout 600000",
            ),
            steer(),
          ],
          { isWorking: true },
        ),
      ),
    },
    "between-steps": {
      note: "Between steps (the reply streams): Not read yet alone; the agent reads it as its next step starts.",
      snapshot: claude(
        chat([prompt(), assistant("Checking the three PRs now", 0, { streaming: true }), steer(0)], {
          isWorking: true,
        }),
      ),
    },
  },
});
