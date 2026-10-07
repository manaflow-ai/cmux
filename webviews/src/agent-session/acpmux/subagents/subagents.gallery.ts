// l10n-allow-file: gallery fixtures (sample prompts, subagent names and tasks), not shipped UI.
// A batch of subagents inline in the transcript (SubagentGroup.tsx): the group row in each state,
// as the snapshot rows the pane receives after direct.ts folds a session's subagent updates. An
// open group's list (SubagentListRow) needs a click on the group; its variants come with the
// gallery's play steps.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, row, summary, user } from "../../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../../gallery/clock";
import { SUBAGENTS, type Subagent } from "./subagentFold";

const prompt = "Audit the fetch helper: retries, errors, timeouts and tests";

/** A subagent started `minutes` ago, ended `ran` minutes later when it is no longer running. */
function agent(
  name: string,
  minutes: number,
  state: Subagent["state"] = "running",
  fields: Partial<Subagent> & { ran?: number } = {},
): Subagent {
  const { ran = 1.5, ...rest } = fields;
  return {
    id: `agent-${name.toLowerCase().replaceAll(" ", "-")}`,
    parent: null,
    name,
    task: name,
    state,
    startedAt: minutesAgo(minutes),
    ...(state !== "running" && { endedAt: minutesAgo(minutes - ran) }),
    ...rest,
  };
}

const group = (agents: Subagent[], minutes: number) => row(SUBAGENTS, minutes, { subagents: agents });

const AUDIT = ["Retry policy", "Error parsing", "Timeouts", "Test coverage"];

export default agentPaneEntry({
  id: "agent-pane.subagents",
  title: "Subagents",
  area: "Agent pane",
  height: 420,
  covers: ["agent-session/acpmux/subagents/SubagentGroup.tsx"],
  variants: {
    running: {
      note: "Four subagents started together, all still working.",
      snapshot: chat(
        [
          user(prompt, 2),
          group(
            AUDIT.map((name) => agent(name, 1.8, "running", { action: `Read ${name.toLowerCase()} code` })),
            1.8,
          ),
        ],
        { isWorking: true },
      ),
    },
    mixed: {
      note: "Some done, one failed, one still working.",
      snapshot: chat(
        [
          user(prompt, 4),
          group(
            [
              agent("Retry policy", 3.8, "completed", { ran: 1.2 }),
              agent("Error parsing", 3.8, "completed", { ran: 2 }),
              agent("Timeouts", 3.8, "failed", { ran: 0.6 }),
              agent("Test coverage", 3.8, "running", { action: "bun test src/net" }),
            ],
            3.8,
          ),
        ],
        { isWorking: true },
      ),
    },
    single: {
      note: "One subagent: no avatar stack overflow, singular count.",
      snapshot: chat([user("Find every caller of request()", 1), group([agent("Find callers", 0.9)], 0.9)], {
        isWorking: true,
      }),
    },
    many: {
      note: "Seven subagents: three avatars, then +4.",
      snapshot: chat(
        [
          user("Review each package for unused exports", 3),
          group(
            ["net", "ui", "store", "router", "i18n", "icons", "tests"].map((name, index) =>
              agent(`Package ${name}`, 2.9, index < 3 ? "completed" : "running", { ran: 0.5 + index * 0.2 }),
            ),
            2.9,
          ),
        ],
        { isWorking: true },
      ),
    },
    done: {
      note: "An ended turn: the group stays in view above the reply, outside Worked for.",
      snapshot: chat([
        user(prompt, 12),
        group(
          AUDIT.map((name, index) => agent(name, 11.8, "completed", { ran: 1 + index * 0.5 })),
          11.8,
        ),
        assistant("All four areas are covered. Two timeouts are too short; the rest is fine.", 9),
        summary(9, { status: "completed", durationMs: 180_000 }),
      ]),
    },
    stopped: {
      note: "A turn stopped while subagents ran: cancelled and disconnected.",
      snapshot: chat([
        user(prompt, 6),
        group(
          [
            agent("Retry policy", 5.8, "completed", { ran: 0.8 }),
            agent("Error parsing", 5.8, "cancelled", { ran: 1.1 }),
            agent("Timeouts", 5.8, "disconnected", { ran: 0.4 }),
          ],
          5.8,
        ),
        summary(4.7, { status: "cancelled" }),
      ]),
    },
    "two-batches": {
      note: "Text between spawns starts a second group.",
      snapshot: chat(
        [
          user(prompt, 8),
          group([agent("Retry policy", 7.8, "completed"), agent("Error parsing", 7.8, "completed", { ran: 2 })], 7.8),
          assistant("Both reviews are in. Now checking timeouts and tests in parallel.", 5.6),
          group([agent("Timeouts", 5.5), agent("Test coverage", 5.5, "running", { action: "bun test src/net" })], 5.5),
        ],
        { isWorking: true },
      ),
    },
  },
});
