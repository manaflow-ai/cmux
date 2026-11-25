// l10n-allow-file: gallery fixtures (sample prompts, replies and a hook's reason), not shipped UI.
// A turn a Stop hook made go on (HookContinueNote.tsx): the agent answered, its Stop hook blocked
// the stop with a reason, and the agent went on. Without the note the text after it read as a
// second answer saying the same thing (Leo, 2026-11-22: "if you did get hooked, i think it should
// get displayed better"). One variant per `hook-continue-look` arm; `line` ships.
import { agentPaneEntry } from "../../../gallery/format";
import { assistant, chat, row, summary, user } from "../../../gallery/fixtures/acpmux";
import { HOOK_CONTINUE } from "./hookContinueKind";
import { hookContinueLook } from "./hookContinueLook.experiment";

const REASON =
  "Notes first: this turn merged manaflow-ai/cmux#4112. Before you stop, save ONE note so the next session finds it instead of reinvestigating.";

const hooked = () =>
  chat([
    user("Land the reconnect fix once CI is green", 6),
    assistant("Merged #4112 as 98c31d6f after all 13 checks passed. The nightly picks it up within the hour.", 5),
    row(HOOK_CONTINUE, 4.9, { hookContinue: { event: "Stop", reason: REASON } }),
    assistant("Saved a note: reconnect drops after sleep; fix in #4112, merged as 98c31d6f.", 4.8),
    summary(4.8, { status: "completed", durationMs: 94_000, toolCount: 6 }),
  ]);

const arm = (look: "line" | "divider" | "chip", note: string) => ({
  note,
  experiments: { [hookContinueLook.id]: look },
  snapshot: hooked(),
});

export default agentPaneEntry({
  id: "agent-pane.hook-continue",
  title: "Stop hook continuation",
  area: "Agent pane",
  height: 480,
  covers: ["agent-session/acpmux/conversation/HookContinueNote.tsx"],
  experiment: { definition: hookContinueLook, script: [{ name: "Rest", run: async () => {} }] },
  variants: {
    line: arm(
      "line",
      "Shipped: a status line like a compaction's, 'Stop hook asked to continue' and the hook's reason, dimmer and cut to the line; the tooltip holds it all.",
    ),
    divider: arm(
      "divider",
      "A hairline divider with 'Stop hook asked to continue' in its middle; the reason is its tooltip.",
    ),
    chip: arm("chip", "A small muted 'Stop hook' chip above the continued text; the reason is its tooltip."),
  },
});
