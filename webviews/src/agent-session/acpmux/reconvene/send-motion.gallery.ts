// l10n-allow-file: gallery fixtures, not shipped UI.
// Reconvene item `send-motion`: sending a prompt feels sluggish and jolty. Leo, 2026-11-09: "ok yeah
// the prompt sending animation feels sluggish but that's not necessarily the fault of the animation...
// everything's just a bit slow rn ... i wonder if we can do a thing where like at really high loads if
// it knows it can't performantly perform the animation... it just goes into minimal ish mode?" Leo,
// 2026-11-07: "the jump, the jolt is a bit too jarring ... what is satisfying at 120 hertz?"
// Starts from leo-workspace design/chat-transcript.md "Streaming reply motion" (the offset lands
// before paint; only the thread's translate chases) and conversation.css SEND-ENTRANCE; the code is
// conversation/followChase.ts (the chase), sendMorph.ts (the composer's prompt flying into its row)
// and followMotion.experiment.ts (gallery agent-pane.send-stream-motion, whose `instant` arm is the
// chase's own opt-out, `data-follow-glide="off"`, used here). Every candidate is set through
// attributes the shipped code already reads on an ancestor: `data-follow-glide`, `data-send-morph`,
// `data-send-entrance`. refs: cursor/live/task-submit-motion (submitting a task: the prompt is placed
// and the reply area appears without a travelling bubble), claude/live/new-code-session-motion (the
// transcript appears at its place, motion limited to a fade), claude/live/composer-fixed-no-scroll-zone
// (the composer is a fixed zone that does not move with the transcript).
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";
import { agentPaneEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import { arms, showArm, type Arm } from "./arm";

const PROMPT = "Now add a test for a 503 that recovers on the second try";
const SENT_ID = "reconvene-send-sent";

const history = [
  user("Add retries to the fetch helper, with a backoff.", 14),
  assistant(
    "Added `withRetry` to `fetchJson`: three tries with jittered backoff, only for network errors and 5xx answers.",
    13,
  ),
  summary(12.9, { status: "completed", durationMs: 24_000, toolCount: 3 }),
  user("Does a 404 retry?", 9),
  assistant("No. A 404 fails at once; only network errors and 5xx answers retry.", 8.5),
  summary(8.4, { status: "completed", durationMs: 6_000, toolCount: 0 }),
  user("Keep the backoff under two seconds in total.", 5),
  assistant("Done: the backoff starts at 200 ms and doubles, capped so three tries wait at most 1.4 s.", 4.5),
  summary(4.4, { status: "completed", durationMs: 9_000, toolCount: 1 }),
];

/// What acpmux sends once the pane's `chat.send` lands: the prompt as its row, the turn running.
const afterSend = chat([...history, user(PROMPT, 0, { id: SENT_ID })], {
  title: "Fetch retries",
  isWorking: true,
});

/// The pane sends through the chat's `chat.send` action, which only a connected acpmux client
/// installs (App.tsx: "Until acpmux connects nothing takes a prompt; the composer keeps it"). This
/// stage has no daemon, so a send never left the composer and no host call came for an `afterCall`
/// to answer. The play stands in for the client's action: acpmux takes the prompt, and its next
/// snapshot (`afterSend`) arrives in a task after, as the transport sends it.
const standInSend = (ctx: PlayContext) => {
  const page = ctx.document.defaultView as unknown as {
    cmuxAcpmuxActions?: Record<string, (params: Record<string, unknown>) => unknown>;
    cmuxAcpmuxBridge?: { receive(snapshot: unknown): void };
  };
  page.cmuxAcpmuxActions = {
    ...page.cmuxAcpmuxActions,
    "chat.send": async (params) => {
      for (const done of [params.accepted, params.taken]) if (typeof done === "function") done();
      setTimeout(() => page.cmuxAcpmuxBridge?.receive(structuredClone(afterSend)), 0);
    },
  };
};

/// Types the prompt at the latest row and sends it, then waits until the sent row is drawn, the
/// composer is empty and every motion rests: the moment just after a send.
const send = async (ctx: PlayContext) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-composer-prompt"), { capMs: 10_000 });
  await ctx.scroll({ selector: ".acpmux-scroll" }, "bottom");
  await ctx.click({ selector: ".acpmux-composer-prompt" });
  await ctx.type(PROMPT);
  await ctx.press("Enter");
  // The prompt field is a text control or an editable box: its text either way.
  const draft = () => {
    const field = ctx.document.querySelector<HTMLElement>(".acpmux-composer-prompt");
    return field instanceof HTMLTextAreaElement || field instanceof HTMLInputElement
      ? field.value
      : (field?.textContent ?? "");
  };
  const sent = () =>
    [...ctx.document.querySelectorAll(".acpmux-user")].some((row) => row.textContent?.includes(PROMPT)) &&
    !draft().includes(PROMPT);
  await ctx.waitFor(sent, { capMs: 10_000 });
  const thread = ctx.document.querySelector<HTMLElement>(".acpmux-thread");
  await ctx.waitFor(() => !thread?.style.translate, { capMs: 2_000 });
  // The turn the send started runs on: its Thinking line's shimmer and the stop button's spinner
  // loop for as long as it does, so only the motions that end count.
  await ctx.waitFor(
    () =>
      !ctx.document.querySelector("[data-send-morph-layer] [data-send-morph-ghost]") &&
      ctx.document
        .getAnimations()
        .every(
          (animation) => animation.playState !== "running" || animation.effect?.getTiming().iterations === Infinity,
        ),
    { capMs: 2_000 },
  );
};

/// The sent bubble draws whole where it lands: no clip, no fade, no text delay.
const NO_ENTRANCE = `
  :root .acpmux-user.acpmux-row--message-enter .acpmux-row__message-presentation,
  :root .acpmux-user.acpmux-row--message-enter .cv-user__bubble,
  :root .acpmux-user.acpmux-row--message-enter .cv-user__bubble > *,
  :root .acpmux-user.acpmux-row--message-enter .cv-user .cv-enter {
    animation: none;
  }`;

export const ARMS = arms<"instant" | "bubble-fade" | "adaptive">({
  // No chase, no flight, no entrance: the prompt is in its row and the composer empty in one frame.
  instant: { css: NO_ENTRANCE, ready: ".acpmux-user" },
  // No chase, no flight: the rows step to their place at once and only the sent bubble fades in
  // there, on the quick step (80 ms) instead of the send's 180 ms.
  "bubble-fade": {
    css: `
  :root .acpmux-user.acpmux-row--message-enter .acpmux-row__message-presentation {
    animation-duration: var(--cmux-motion-quick);
    animation-timing-function: var(--cmux-ease-out);
  }`,
    ready: ".acpmux-user",
  },
  // Behaviour, not look: the shipped send while frames keep up, `instant` when they do not. Drawn here
  // as its under-load outcome.
  adaptive: { css: NO_ENTRANCE, ready: ".acpmux-user" },
});

/// The attributes that take the motion out: the chase steps (`data-follow-glide="off"`, the
/// follow-motion experiment's `instant`), the composer's prompt is not copied into the row
/// (`data-send-morph="inplace"`), and the bubble's entrance is the plain fade (`data-send-entrance`).
const MINIMAL = { "follow-glide": "off", "send-morph": "inplace", "send-entrance": "fade" };

const variant = (note: string, arm?: Arm) => ({
  note,
  snapshot: chat(history, { title: "Fetch retries" }),
  ...(arm ? { documentAttributes: MINIMAL } : {}),
  play: async (ctx: PlayContext) => {
    standInSend(ctx);
    if (arm) await showArm(ctx, { css: arm.css });
    await send(ctx);
    if (arm) await showArm(ctx, arm);
  },
});

export default agentPaneEntry({
  id: "agent-pane.reconvene-send-motion",
  title: "Reconvene: the motion of a send",
  area: "Agent pane",
  height: 560,
  covers: ["agent-session/acpmux/VirtualTranscript.tsx#VirtualTranscript", "agent-session/acpmux/Composer.tsx"],
  variants: {
    now: variant(
      "Shipped: the composer's prompt flies into its bubble while the thread rises into its room on the chase (spring, 180 ms send step), the thinking row fading in on the same clock.",
    ),
    instant: variant(
      "The sent prompt is in its row, the rows at their place and the composer empty in the frame of the send; nothing moves after it. Never lags; the rise reads as a cut.",
      ARMS.instant,
    ),
    "bubble-fade": variant(
      "No chase and no flight: the rows step at once and only the sent bubble fades in at its final place (80 ms). Opacity only, so it costs no layout; a little softer than instant.",
      ARMS["bubble-fade"],
    ),
    adaptive: variant(
      "Behaviour (drawn as its under-load outcome, instant): the shipped chase, but a send whose last 250 ms before it had a frame over 50 ms (fold.ts FOLD_DROP_MS, a Long Animation Frame) goes instant. Smooth when idle; the look changes with load.",
      ARMS.adaptive,
    ),
  },
});
