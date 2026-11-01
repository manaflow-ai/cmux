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
import { claudeModels, codexModels } from "./mockFixture";

const prompt = "Run the sidebar tests and fix what fails.";
const seeded = { transport: "mock", newSession: true, harness: "claude", prompt };
/// The mock daemon's harnesses with the level a new chat starts on, as acpmux lists them
/// (`_acpmux/harnesses` start), so the model chip names its effort while the agent starts too.
const startingHarnesses = [
  { id: "claude", name: "Claude Code", models: claudeModels, start: { effort: "medium", effortSource: "catalog" } },
  { id: "codex", name: "Codex", models: codexModels, start: { effort: "high", effortSource: "catalog" } },
];

/// The prompt is on screen as sent, the line under it, while the agent starts.
const sent: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".cv-user__bubble"));
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-thinking .cv-worked"));
};

/// The agent starts and answers: nothing above the composer moves, and the prompt keeps its place.
/// The play's own layout-shift observer spans the whole start (the step's own measure ends when
/// the hover settles, before the agent is up), and the line under the prompt must keep its top
/// from the send to the first output (the start row once moved 28 px down when the turn opened).
const toReply: Play = async (ctx) => {
  const doc = ctx.document;
  const view = doc.defaultView!;
  await sent(ctx);
  const shifts: { value: number; from: string }[] = [];
  const observer = new view.PerformanceObserver((list) => {
    for (const entry of list.getEntries() as (PerformanceEntry & {
      value: number;
      sources?: { node?: Node; previousRect?: DOMRectReadOnly; currentRect?: DOMRectReadOnly }[];
    })[]) {
      // The chat header is out of scope: its Needs you badge widens whenever its count changes,
      // whatever the start does (cmux#30663).
      const moved = (entry.sources ?? []).filter(
        (source) =>
          !(source.node instanceof view.Element && source.node.closest(".acpmux-header")) &&
          source.previousRect &&
          source.currentRect &&
          Math.max(
            Math.abs(source.previousRect.y - source.currentRect.y),
            Math.abs(source.previousRect.x - source.currentRect.x),
          ) >= 0.5,
      );
      if (moved.length === 0) continue;
      const { node, previousRect: was, currentRect: now } = moved[0]!;
      const name =
        node instanceof view.Element
          ? `${node.className.toString()} "${(node.getAttribute("aria-label") || node.textContent || "").trim().slice(0, 60)}"`
          : "#text";
      const delta = [now!.x - was!.x, now!.y - was!.y, now!.width - was!.width, now!.height - was!.height];
      shifts.push({ value: entry.value, from: `${name} [${delta.map((d) => Math.round(d * 10) / 10).join(" ")}]` });
    }
  });
  if (view.PerformanceObserver.supportedEntryTypes?.includes("layout-shift"))
    observer.observe({ type: "layout-shift", buffered: false });
  const line = () => doc.querySelector(".acpmux-thinking .cv-worked")?.getBoundingClientRect().top;
  const bubble = doc.querySelector(".cv-user__bubble")?.getBoundingClientRect();
  // The line's top on every frame and mutation from the send until the first output.
  const tops: number[] = [];
  const track = () => {
    const top = line();
    if (top !== undefined) tops.push(top);
  };
  track();
  await ctx.hover({ selector: ".cv-user__bubble" });
  await ctx.waitFor(
    () => {
      const reply = doc.querySelector(".cv-md");
      if (!reply) track();
      return reply;
    },
    { capMs: 15_000 },
  );
  observer.disconnect();
  const moved = doc.querySelector(".cv-user__bubble")?.getBoundingClientRect();
  const problems: string[] = [];
  if (bubble && moved && Math.abs(bubble.top - moved.top) > 1)
    problems.push(`the prompt moved ${Math.abs(bubble.top - moved.top).toFixed(1)} px`);
  const travel = tops.length ? Math.max(...tops) - Math.min(...tops) : 0;
  if (travel > 1) problems.push(`the line under the prompt moved ${travel.toFixed(1)} px while the agent started`);
  if (shifts.length > 0)
    problems.push(
      `${shifts.length} layout shift(s) while the agent started, CLS ${shifts.reduce((sum, shift) => sum + shift.value, 0).toFixed(4)} (${shifts.map((shift) => shift.from).join(", ")})`,
    );
  if (problems.length) throw new Error(problems.join("; "));
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
    "slow-start": {
      note: "Play: the agent takes 2.5 s to start, then answers. The prompt, the line and the composer keep their places.",
      ready: seeded,
      mockHarnesses: startingHarnesses,
      mockStart: { delayMs: 2_500 },
      snapshot: noChat([]),
      play: toReply,
    },
    starting: {
      note: "The agent is still starting: the prompt reads as sent, Thinking runs under it, and the composer offers Stop.",
      ready: seeded,
      mockHarnesses: startingHarnesses,
      mockStart: { delayMs: 600_000 },
      snapshot: noChat([]),
      play: sent,
    },
    "failed-start": {
      note: "The agent could not start: the reason with Retry above the composer, and the prompt back in it to send again.",
      ready: seeded,
      mockHarnesses: startingHarnesses,
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
