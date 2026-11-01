// l10n-allow-file: gallery fixtures (sample messages, lane names and tool output), not shipped UI.
// The transcript's hover-revealed controls fade in and out on the message hover row's fade (#23769,
// conversation.css --cv-actions-*) instead of blinking (Leo, 2026-10-28: "there should be, like, a
// fast fade-in fade-out. Right now they're just appearing and disappearing. Like they're just
// blinking in and out of existence, and it's a bit jarring"). Each state comes twice: pointed at
// and settled, and caught partway into its fade in (the fade slowed and held at the same point
// every run), where a control that blinks shows at full strength and one that fades shows faint.
// test/transcript-hover-fade.test.ts holds every hover-revealed transcript control to the fade.
import { agentPaneEntry } from "../../../gallery/format";
import type { Play, PlayContext } from "../../../gallery/play";
import { activity, assistant, chat, summary, tool, user } from "../../../gallery/fixtures/acpmux";

const ASK =
  "Helper for #26409 on the lane VM: I can only message the broker host. Please relay to launch-polish that I'm claiming it, rebasing onto feat-cmux-next and fixing the three review blockers.";
const LOG = [
  "retry 1/3 GET /v1/runs -> 503 after 412 ms",
  "retry 2/3 GET /v1/runs -> 503 after 820 ms",
  "retry 3/3 GET /v1/runs -> 200 after 96 ms",
  "done: 3 attempts, 1.33 s",
].join("\n");

/// The fade's length while caught, and the point it is held at: 15% of the way in time, which the
/// snap curve puts a little under half strength.
const SLOW_FADE_MS = 2000;
const HELD_AT_MS = 300;

/// Slows the fade in (no delay) before the pointer arrives, so it is still running when caught.
const slowFade = (ctx: PlayContext) => {
  const root = ctx.document.documentElement.style;
  root.setProperty("--cv-actions-in", `${SLOW_FADE_MS}ms`);
  root.setProperty("--cv-actions-in-delay", "0ms");
};

/// Holds every opacity fade the pointer started at HELD_AT_MS. A control with no fade has none to
/// hold: it already shows at full strength.
const holdFades = (ctx: PlayContext) => {
  for (const animation of ctx.document.getAnimations()) {
    if (!(animation instanceof CSSTransition) || animation.transitionProperty !== "opacity") continue;
    animation.pause();
    animation.currentTime = HELD_AT_MS;
  }
};

/// Points at `target` once `before` has run; with `caught`, holds the fades it started partway.
const pointAt =
  (target: string, { caught = false, before }: { caught?: boolean; before?: Play } = {}): Play =>
  async (ctx) => {
    await before?.(ctx);
    if (caught) slowFade(ctx);
    await ctx.hover({ selector: target });
    if (caught) holdFades(ctx);
  };

/// Another agent's message the agent has not read yet, from a chat here, in the group of messages
/// that wait (opened): Reply, its age and ⋯ in its line's plate on hover.
const received = () =>
  chat(
    [
      user("Ask the lane VM helper where #26409 stands", 9, { seq: 1 }),
      assistant("Asked it; it will report back here.", 8.5),
      activity([tool("gh pr view 26409", "execute", "in_progress", { command: "gh pr view 26409" })], 8),
      user(ASK, 2, {
        seq: 4,
        id: "gallery-hover-fade-received",
        untyped: true,
        incoming: {
          kind: "message",
          message: {
            name: "gcp-agent-lane-2/attach-final-loop",
            sessionId: "lane-2",
            text: ASK,
            raw: ASK,
            msgId: "m-1",
            threadId: "t-1",
          },
        },
        steer: "waiting",
        steerPromptId: "p-gallery-hover-fade",
      }),
    ],
    { isWorking: true },
  );
const RECEIVED_LINE = ".cv-received > .cv-disclosure__line";
/// Opens the group of waiting messages, which shows collapsed (PendingMessagesCard.tsx).
const openWaiting: Play = async (ctx) => {
  await ctx.click({ selector: ".cv-pending__toggle" });
  await ctx.waitFor(() => ctx.document.querySelector(RECEIVED_LINE));
};

/// A finished call's output, opened: Wrap lines in its corner on hover.
const output = () =>
  chat([
    user("Fetch the retry log", 3),
    activity([tool("Fetch the retry log", "fetch", "completed", { output: LOG })], 2.8),
    assistant("Three tries; the last one answered in 96 ms.", 2.6),
    summary(2.6, { status: "completed", toolCount: 1 }),
  ]);
/// Every animation but a loop has finished.
const settled = (ctx: PlayContext) =>
  ctx.document.getAnimations().every((animation) => {
    const loops = animation.effect?.getComputedTiming().endTime === Infinity;
    return loops || animation.playState !== "running";
  });
const openOutput: Play = async (ctx) => {
  if (!ctx.document.querySelector(".cv-tool.is-toggle")) {
    await ctx.click({ selector: ".cv-worked" });
    await ctx.waitFor(() => ctx.find({ selector: ".cv-worked" }).getAttribute("aria-expanded") === "true");
  }
  await ctx.click({ selector: ".cv-tool.is-toggle" });
  // The fold has opened: the box is where the pointer will find it.
  await ctx.waitFor(() => Boolean(ctx.document.querySelector(".cv-tool-output__box")) && settled(ctx));
};

export default agentPaneEntry({
  id: "agent-pane.hover-fade",
  title: "Hover controls fade",
  area: "Agent pane",
  height: 420,
  covers: [
    "agent-session/acpmux/conversation/IncomingMessageCard.tsx",
    "agent-session/acpmux/conversation/QueuedMessageCard.tsx",
    "agent-session/acpmux/conversation/ToolRow.tsx",
  ],
  variants: {
    received: {
      note: "Another agent's waiting message, its group opened, pointed at: Reply, its age and ⋯ in the line's plate. No Pin and no hover Copy on another session's message; its name opens its chat.",
      snapshot: received(),
      play: pointAt(RECEIVED_LINE, { before: openWaiting }),
    },
    "received-fading-in": {
      note: "The same line caught partway into its fade in: Reply comes in faint with the rest of the row, as the age always did. Before, it blinked in at full strength.",
      snapshot: received(),
      play: pointAt(RECEIVED_LINE, { caught: true, before: openWaiting }),
    },
    "tool-output": {
      note: "A finished call's output, opened and pointed at: Wrap lines in its corner.",
      snapshot: output(),
      play: pointAt(".cv-tool-output__box", { before: openOutput }),
    },
    "tool-output-fading-in": {
      note: "The same output caught partway into its fade in: Wrap lines comes in faint. Before, it blinked in at full strength.",
      snapshot: output(),
      play: pointAt(".cv-tool-output__box", { caught: true, before: openOutput }),
    },
  },
});
