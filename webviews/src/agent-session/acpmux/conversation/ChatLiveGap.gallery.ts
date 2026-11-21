// l10n-allow-file: gallery fixtures (prompts, replies and commands), not shipped UI.
// Leo, 2026-11-21 05:23Z: "see the space/gap between tool calls and the current shimmer? this isnt great."
// The running turn's live line under a run and under a reply, in each look of transcriptGrid.ts LIVE_GAP_LOOKS
// (`<html data-live-gap>`). The `-run` and `-reply` variants of one look are the two states the row over the line
// keeps switching between; the line's top and words must sit at the same place in both
// (test/transcript-live-line-holds-browser.test.ts).
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, tool, user } from "../../../gallery/fixtures/acpmux";
import type { AcpmuxActivity, AcpmuxSnapshot } from "../model";

const run = (command: string): AcpmuxActivity =>
  tool(command, "execute", "completed", { command, exitCode: 0, output: "ok\n" });

function running(over: "run" | "reply"): AcpmuxSnapshot {
  return chat(
    [
      user("Find every retry loop and cap it at three attempts.", 3),
      assistant("I'll find the retry loops first.", 2.9),
      activity([run("rg -n 'retry' src"), run("rg -n 'sleep' src/net"), run("cat src/net/fetch.ts")], 2.8),
      ...(over === "reply"
        ? [assistant("Two loops retry forever: the fetch client and the upload queue. Capping both now.", 2.5)]
        : []),
    ],
    { isWorking: true },
  );
}

const LOOKS = {
  before: "Before: the run gap (16) over the footer's 32 slot, its words centred in it: 43 from a step row's centre.",
  jumps:
    "The bare flip: the footer gap (8) over a 22 row under a run, the 32 slot under a reply. 30 under a run, but the line moves at each switch.",
  slot8:
    "Fallback: the footer gap (8) over the 32 slot, its words centred in it: 35 from a step row's centre, no jump.",
  shipped:
    "The pick (variant B): the footer gap (8) over a 22 box drawn at the top of the 32 slot, under a run and a reply alike: 30 from a step row's centre, no jump.",
} as const;
const variants: Record<string, Record<string, unknown>> = {};
for (const [look, note] of Object.entries(LOOKS))
  for (const over of ["run", "reply"] as const)
    variants[`${look}-${over}`] = {
      note: `${note} The row over the line is a ${over}.`,
      snapshot: running(over),
      documentAttributes: { "live-gap": look },
    };

export default agentPaneEntry({
  id: "agent-pane.chat-live-gap",
  title: "Chat live line: the gap and box under a run and a reply",
  area: "Agent pane",
  height: 420,
  covers: [
    "agent-session/acpmux/transcriptGrid.ts",
    "agent-session/acpmux/model.ts",
    "agent-session/acpmux/conversation/conversation.css",
  ],
  variants: variants as never,
});
