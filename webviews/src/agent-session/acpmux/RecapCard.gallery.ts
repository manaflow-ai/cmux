// l10n-allow-file: gallery fixtures (sample prompts and agent answers), not shipped UI.
// The recap card above the composer (RecapCard.tsx, behind the agent.sessionStatus Debug toggle):
// the last turn completed by asking something, so the card shows the answer's last paragraph, the
// question and its yes. Light and dark come from the gallery's appearance control.
import { agentPaneEntry } from "../../gallery/format";
import { activity, assistant, chat, summary, tool, user } from "../../gallery/fixtures/acpmux";

const SUMMARY =
  "Product images now have a width and height, and the grid reserves a 4:5 box while they load, so the product grid no longer shifts. All 14 tests pass, including the new layout shift test.";

const turn = (answer: string) =>
  chat([
    user("Fix the layout shift on the product grid", 4),
    activity(
      [
        tool("Edit ProductCard.tsx", "edit", "completed"),
        tool("bun test", "execute", "completed", { command: "bun test", output: "14 pass\n", exitCode: 0 }),
      ],
      3,
    ),
    assistant(answer, 2),
    summary(2, { status: "completed", durationMs: 48_000, toolCount: 2 }),
  ]);

export default agentPaneEntry({
  id: "agent-pane.recap-card",
  title: "Recap card",
  area: "Agent pane",
  // Behind the agent.sessionStatus Debug toggle until it ships.
  experimental: true,
  height: 520,
  covers: ["agent-session/acpmux/RecapCard.tsx"],
  variants: {
    "recap-card": {
      note: "The turn ends asking to open a PR: Yes, open PR (⌘↩), Not now and ×.",
      sessionStatus: true,
      snapshot: turn(`${SUMMARY}\n\nShould I open a PR for this?`),
    },
    "recap-card-plain-yes": {
      note: "A question that offers no short action: a plain Yes.",
      sessionStatus: true,
      snapshot: turn(`${SUMMARY}\n\nDoes the grid look right on your phone?`),
    },
    "recap-card-off": {
      note: "The toggle off: the same turn shows no card.",
      snapshot: turn(`${SUMMARY}\n\nShould I open a PR for this?`),
    },
  },
});
