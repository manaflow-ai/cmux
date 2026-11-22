// l10n-allow-file: gallery fixtures (sample prompts, commands and messages), not shipped UI.
// The person's prompt right after a run of tool rows (Leo, 2026-11-01, on a steer that sat nearly
// touching the "Sent to …" line over it while its time row and the next call had far more room under
// it: "this is too close to tool calls, center it"). A running turn: its prompt, three one-line tool
// rows (a command, a sent message, a command), then a steer the person sent into the turn, then two
// more calls (the latest draws as the live line). The steer's bubble sits in the middle of its gap:
// the turn gap (grid.md 5.5, 32px) from the tool line over it to its top and from its bottom to the
// next tool line, its hover meta row (time, Copy, Retry) laid in the room under it
// (transcript-prompt-after-tools.test.ts).
import { agentPaneEntry } from "../../../gallery/format";
import { activity, chat, tool, user } from "../../../gallery/fixtures/acpmux";

const command = (title: string, line: string) =>
  tool(title, "execute", "completed", { command: line, description: title });

const rows = [
  user("Check the fleet for idle machines and stray sessions.", 10),
  activity([command("List the fleet's machines", "reach --list")], 9.9),
  activity([command("Show each lane's load", "sessions ls --load")], 9.8),
  activity([command("Find idle runners", "ci runners --idle")], 9.7),
  user(
    "make sure we're not randomly wasting money on random agents doing ineffective/inefficient stuff nor leaving machines idle for no reason",
    9.6,
    { steer: "landed" },
  ),
  activity([command("Show the paid hosts' utilization", "fleet-utilization --paid")], 9.5),
  activity([command("Stop the idle lane VMs", "sessions stop --idle")], 9.4),
];

const snapshot = chat(rows, { title: "Fleet idle check", isWorking: true });

export default agentPaneEntry({
  id: "agent-pane.prompt-after-tool-rows",
  title: "A prompt after tool rows",
  area: "Agent pane",
  height: 420,
  covers: [
    "agent-session/acpmux/conversation/UserBubble.tsx",
    "agent-session/acpmux/conversation/conversation.css",
    "agent-session/acpmux/model.ts",
  ],
  variants: {
    centered: {
      note: "Shipped: centred. The turn gap (32px) from the tool line over the bubble to its top, and from its bottom to the next tool line.",
      snapshot,
    },
  },
});
