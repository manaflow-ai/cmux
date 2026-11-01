// l10n-allow-file: gallery fixtures (a sample prompt and a start error), not shipped UI.
// A new chat whose agent is still starting (harnessSwitch.ts): the prompt the New Tab page seeded
// shows at once as sent, the line under it already runs, and the composer is usable with Stop,
// which takes the prompt back. No "Starting Claude Code… Cancel" row and no layout shift when the
// turn opens (Leo, 2026-11-01: "i hate the "Starting Claude Code... cancel" thing that it starts
// with" / "then the stupid ass layout shift" / "surely we can have a better load/faster load/intro
// than that"). The pane runs its real client against the in-page mock daemon, whose `session/new`
// answers late or refuses (`mockStart`). Compare arms shows the `agent-start-look` experiment.
import { agentPaneEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { noChat } from "../../gallery/fixtures/acpmux";
import { agentStartLook } from "./conversation/agentStart.experiment";

const prompt = "Run the sidebar tests and fix what fails.";
const seeded = { transport: "mock", newSession: true, harness: "claude", prompt };

/// The prompt is on screen as sent, the line under it, while the agent starts.
const sent: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".cv-user__bubble"));
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-thinking .cv-worked"));
};

/// The agent starts and answers: nothing above the composer moves, and the prompt keeps its place.
const toReply: Play = async (ctx) => {
  const doc = ctx.document;
  await sent(ctx);
  const bubble = doc.querySelector(".cv-user__bubble")?.getBoundingClientRect();
  await ctx.hover({ selector: ".cv-user__bubble" });
  await ctx.waitFor(() => doc.querySelector(".cv-md"), { capMs: 15_000 });
  const moved = doc.querySelector(".cv-user__bubble")?.getBoundingClientRect();
  if (bubble && moved && Math.abs(bubble.top - moved.top) > 1)
    throw new Error(`the prompt moved ${Math.abs(bubble.top - moved.top).toFixed(1)} px when its agent started`);
};

export default agentPaneEntry({
  id: "agent-pane.agent-start",
  title: "New chat: agent starting",
  area: "Agent pane",
  height: 520,
  widths: { narrow: 420, normal: 760, wide: 760 },
  anchors: [
    { selector: ".acpmux-composer-box" },
    { selector: ".acpmux-composer-bar" },
    { selector: ".acpmux-model" },
    { selector: ".acpmux-fit-mic" },
  ],
  checks: {
    longFrameFailMs: {
      value: 150,
      reason:
        "The mock daemon's first session and the first transcript mount share one frame on the CPU-only gallery VM, as in agent-pane.new-chat-no-shift; this entry gates layout shift.",
    },
  },
  covers: ["agent-session/acpmux/conversation/agentStart.experiment.ts"],
  keywords: ["start", "starting", "loading", "new chat", "layout shift", "cancel"],
  variants: {
    starting: {
      note: "The agent is still starting: the prompt reads as sent, Thinking runs under it, and the composer offers Stop.",
      ready: seeded,
      mockStart: { delayMs: 600_000 },
      snapshot: noChat([]),
      play: sent,
    },
    "slow-start": {
      note: "Play: the agent takes 2.5 s to start, then answers. The prompt, the line and the composer keep their places.",
      ready: seeded,
      mockStart: { delayMs: 2_500 },
      snapshot: noChat([]),
      play: toReply,
    },
    "failed-start": {
      note: "The agent could not start: the reason with Retry above the composer, and the prompt back in it to send again.",
      ready: seeded,
      mockStart: { error: "Claude Code exited before it started (exit code 1)." },
      snapshot: noChat([]),
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-switch-failed"), { capMs: 10_000 });
      },
    },
  },
  experiment: {
    definition: agentStartLook,
    script: [
      { name: "sent, agent starting", run: sent },
      {
        name: "turn opens",
        run: async (ctx) => {
          await ctx.waitFor(() => ctx.document.querySelector(".cv-md"), { capMs: 15_000 });
        },
      },
    ],
  },
});
