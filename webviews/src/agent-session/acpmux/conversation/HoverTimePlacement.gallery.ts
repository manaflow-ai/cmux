// l10n-allow-file: gallery sample transcript, not shipped UI.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, summary, tool, user } from "../../../gallery/fixtures/acpmux";

const snapshot = () =>
  chat([
    user("Check the tests", 4),
    activity([tool("Run tests", "execute", "completed", { command: "bun test", output: "Passed" })], 3),
    summary(2, { status: "completed", durationMs: 46_000, toolCount: 1 }),
    user("What changed?", 1),
    assistant("The tests pass.", 0.5),
    summary(0.4, { status: "completed", durationMs: 20_000 }),
  ]);

export default agentPaneEntry({
  id: "agent-pane.hover-time-placement",
  title: "Hover time beside row content",
  area: "Agent pane",
  height: 620,
  widths: { narrow: 360, normal: 760 },
  covers: ["agent-session/acpmux/conversation/TurnRows.tsx", "agent-session/acpmux/conversation/MessageActions.tsx"],
  variants: {
    inline: { snapshot: snapshot(), note: "The time follows the row's content in its own space." },
    trailing: { snapshot: snapshot(), note: "Compare a time at the trailing edge." },
    separated: { snapshot: snapshot(), note: "Compare a larger gap after the row's content." },
  },
});
