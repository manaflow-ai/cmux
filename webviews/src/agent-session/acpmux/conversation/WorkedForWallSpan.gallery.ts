// l10n-allow-file: gallery fixtures (sample prompts and tool titles), not shipped UI.
// A finished turn's "Worked for" reads the turn's wall span, first event to last: its thinking, its
// model round trips and every tool call's own timeline, never less than its footer's Timeline total
// (Leo, 2026-11-27: "but shouldn't the worked for count the timelines of the tool calls"). A turn
// under a second reads "0s" (Leo: "let's do not <1 but 0s and revert that situatoin").
import { agentPaneEntry } from "../../../gallery/format";
import { GALLERY_NOW } from "../../../gallery/clock";
import { activity, chat, row, thought, tool, user } from "../../../gallery/fixtures/acpmux";

const at = (ms: number) => GALLERY_NOW - 60_000 + ms;

/// The turn in Leo's capture: a short thought, an answer 300ms in, and two calls that ran on to
/// 2.8s. The harness's own record says the turn took 300ms.
const outlasting = () =>
  chat([
    { ...user("Queue lands for #60053 and #60188", 1, { id: "wall-prompt" }), at: at(0) },
    {
      ...activity(
        [
          thought("Queue both lands", { startedAt: at(0), endedAt: at(3) }),
          tool("Queue lands for #60053 and #60188", "execute", "completed", {
            command: "cmux-gh land 60053 60188 --queue",
            startedAt: at(300),
            endedAt: at(2_500),
          }),
          tool("Sent a message", "other", "completed", { startedAt: at(300), endedAt: at(2_800) }),
        ],
        1,
        { id: "wall-act" },
      ),
      at: at(10),
    },
    {
      ...row("assistant", 1, { id: "wall-answer", text: "Queued both.", assistantPhase: "final_answer" }),
      at: at(300),
    },
    {
      ...row("turnSummary", 1, {
        id: "wall-summary",
        status: "completed",
        toolCount: 2,
        durationMs: 300,
        turnStartedAtMs: at(0),
      }),
      at: at(300),
    },
  ]);

/// A turn whose whole span is under a second.
const quick = () =>
  chat([
    { ...user("What branch am I on?", 1, { id: "quick-wall-prompt" }), at: at(0) },
    {
      ...activity(
        [
          tool("git branch --show-current", "execute", "completed", {
            command: "git branch --show-current",
            startedAt: at(80),
            endedAt: at(240),
          }),
          tool("git status --short", "execute", "completed", {
            command: "git status --short",
            startedAt: at(240),
            endedAt: at(420),
          }),
        ],
        1,
        { id: "quick-wall-act" },
      ),
      at: at(10),
    },
    {
      ...row("assistant", 1, { id: "quick-wall-answer", text: "feat-cmux-next, clean.", assistantPhase: "final_answer" }),
      at: at(600),
    },
    {
      ...row("turnSummary", 1, {
        id: "quick-wall-summary",
        status: "completed",
        toolCount: 2,
        durationMs: 600,
        turnStartedAtMs: at(0),
      }),
      at: at(600),
    },
  ]);

export default agentPaneEntry({
  id: "agent-pane.worked-for-wall-span",
  title: "Worked for: the turn's wall span, tools included; 0s under a second",
  area: "Agent pane",
  height: 320,
  covers: [
    "agent-session/acpmux/conversation/turns.ts",
    "agent-session/acpmux/conversation/waterfallSpans.ts",
    "agent-session/acpmux/conversation/TurnWaterfall.tsx",
  ],
  keywords: ["worked for", "0s", "timeline", "waterfall", "duration", "tool calls"],
  variants: {
    "tools-outlast-answer": {
      note: "Two calls ran on 2.5s past the answer: Worked for reads 2s, the Timeline's 2.8s total floored, never 0s.",
      snapshot: outlasting(),
      // Opened, the turn's Timeline stands under the Worked for it must never exceed.
      play: async (ctx) => {
        await ctx.hover({ selector: ".acpmux-turnSummary, .cv-turn-actions" });
        await ctx.click({ selector: ".cv-waterfall-toggle" });
        await ctx.waitFor(() => ctx.document.querySelector(".cv-waterfall"));
      },
    },
    "under-a-second": {
      note: 'A turn of 600ms: "Worked for 0s", not "<1s".',
      snapshot: quick(),
    },
  },
});
