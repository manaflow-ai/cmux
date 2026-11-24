// Temporary gallery stage for narrow-width composer hat captures. Delete after capture.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, row, user } from "../../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../../gallery/clock";
import { SUBAGENTS, type Subagent } from "./subagentFold";

const tasks = [
  ["Inspect the fetch helper", "Read src/net/fetch.ts"],
  ["Check retry coverage", "Read src/net/fetch.test.ts"],
  ["Review timeout behavior", "Grep timeout settings"],
  ["Run focused tests", "bun test src/net"],
  ["Check error handling", "Read src/net/errors.ts"],
] as const;

function agent(index: number): Subagent {
  const [task, action] = tasks[index] ?? ["Review shard " + (index + 1), "Read the next file"];
  return {
    id: "hat-shot-agent-" + (index + 1),
    parent: null,
    name: "general-purpose",
    task,
    kind: "general-purpose",
    state: "running",
    background: true,
    startedAt: minutesAgo(2 + index * 0.25),
    action,
  };
}

function snapshot(count: number) {
  const rows = [
    user("Review the fetch helper and keep the checks running", 6),
    assistant("The review is underway and the focused checks are still running.", 3),
    ...(count > 0 ? [row(SUBAGENTS, 2, { subagents: Array.from({ length: count }, (_, index) => agent(index)) })] : []),
  ];
  return chat(rows, {
    harness: "codex",
    model: "gpt-6-astra",
    isWorking: count > 0,
  });
}

export default agentPaneEntry({
  id: "agent-pane.composer-hat-shots",
  title: "Composer hat narrow-width captures",
  area: "Agent pane",
  height: 560,
  anchors: [{ selector: ".acpmux-composer" }],
  covers: ["agent-session/acpmux/Composer.tsx#Composer", "agent-session/acpmux/subagents/SubagentTray.tsx"],
  variants: {
    zero: { note: "No background subagents running.", snapshot: snapshot(0) },
    one: { note: "One background subagent running.", snapshot: snapshot(1) },
    five: { note: "Five background subagents running.", snapshot: snapshot(5) },
  },
});
