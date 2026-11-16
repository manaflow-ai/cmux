// l10n-allow-file: gallery-only recorded chat and sample diagnoses.
// The real pane, composer, and bridge are mounted here. A stuck episode is attention on a live
// chat, not a change to its run state; the person can edit a nudge without sending or stopping it.
import { agentPaneEntry } from "../../gallery/format";
import type { PlayContext } from "../../gallery/play";
import { assistant, chat, user } from "../../gallery/fixtures/acpmux";
import type { AcpmuxSnapshot } from "./model";

const diagnosis = "Ran cargo test 4 times; the same error in auth.rs:88 each time";
const base = chat([user("Fix the auth tests.", 4), assistant("I am checking the failing auth test.", 3)], {
  isWorking: true,
  title: "Fix the auth tests",
});
const loop: AcpmuxSnapshot = {
  ...base,
  summary: {
    ...base.summary!,
    status: "running",
    loopEpisode: { episodeId: 1, since: 1_783_517_200_000, count: 4, diagnosis, hint: diagnosis },
  },
};
const silent: AcpmuxSnapshot = {
  ...base,
  summary: { ...base.summary!, status: "running", stalledSince: 1_783_517_200_000 },
};
const progressed: AcpmuxSnapshot = {
  ...loop,
  summary: { ...loop.summary!, loopEpisode: undefined, stalledSince: undefined },
};

type Bridge = { receive(snapshot: AcpmuxSnapshot): void };
const bridge = (ctx: PlayContext): Bridge => {
  const value = (ctx.document.defaultView as unknown as { cmuxAcpmuxBridge?: Bridge }).cmuxAcpmuxBridge;
  if (!value) throw new Error("the pane bridge is not installed");
  return value;
};
const editor = ".acpmux-composer > .acpmux-composer-box [contenteditable='true']";
const box = ".acpmux-composer > .acpmux-composer-box";
const bounds = (ctx: PlayContext) => {
  const rect = ctx.document.querySelector(box)?.getBoundingClientRect();
  if (!rect) throw new Error("the real composer box is missing");
  return { x: rect.x, y: rect.y, width: rect.width, height: rect.height };
};
const unchanged = (before: ReturnType<typeof bounds>, after: ReturnType<typeof bounds>) => {
  for (const key of ["x", "y", "width", "height"] as const)
    if (Math.abs(before[key] - after[key]) > 0.5) throw new Error(`composer ${key} changed with attention`);
};
const liveAttention = async (ctx: PlayContext) => {
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-main[data-stuck] .acpmux-stuck-banner"));
  // Pseudo-elements are not DOM nodes; the attribute and computed style establish the pane ring.
  const pane = ctx.document.querySelector<HTMLElement>(".acpmux-main[data-stuck]")!;
  if (pane.ownerDocument.defaultView!.getComputedStyle(pane, "::after").content === "none")
    throw new Error("chat pane ring is missing");
};
const quickAttention = async (ctx: PlayContext) => {
  await ctx.waitFor(() =>
    ctx.document.querySelector('.acpmux-shell[data-surface="quick"][data-stuck] .acpmux-stuck-banner'),
  );
  const pane = ctx.document.querySelector<HTMLElement>('.acpmux-shell[data-surface="quick"][data-stuck]')!;
  if (pane.ownerDocument.defaultView!.getComputedStyle(pane, "::after").content === "none")
    throw new Error("quick chat ring is missing");
};

const editNudge = async (ctx: PlayContext) => {
  await liveAttention(ctx);
  const existingDraft = "Check the auth regression too.";
  await ctx.type(existingDraft, { selector: editor });
  if (!ctx.document.querySelector(editor)?.textContent?.includes(existingDraft))
    throw new Error("the existing draft was not entered");
  const log = (ctx.document.defaultView as unknown as { cmuxGalleryLog: { method: string }[] }).cmuxGalleryLog;
  const callsBefore = log.length;
  const beforeNudge = bounds(ctx);
  const banner = ctx.document.querySelector(".acpmux-stuck-banner")!;
  const bannerTop = banner.getBoundingClientRect().top;
  await ctx.click({ selector: ".acpmux-stuck-nudge" });
  await ctx.waitFor(() => ctx.document.querySelector(editor)?.textContent?.includes(diagnosis));
  const afterNudge = bounds(ctx);
  // Inserting a multiline draft grows the existing composer upwards. Its bottom edge
  // stays fixed, and the diagnosis must follow its top by exactly the same distance.
  if (
    Math.abs(afterNudge.x - beforeNudge.x) > 0.5 ||
    Math.abs(afterNudge.width - beforeNudge.width) > 0.5 ||
    Math.abs(afterNudge.y + afterNudge.height - beforeNudge.y - beforeNudge.height) > 0.5 ||
    afterNudge.height < beforeNudge.height - 0.5 ||
    afterNudge.height - beforeNudge.height > 160 ||
    Math.abs(banner.getBoundingClientRect().top - bannerTop - (afterNudge.y - beforeNudge.y)) > 0.5
  )
    throw new Error("nudge growth moved the composer anchor or separated the diagnosis");
  const text = ctx.document.querySelector(editor)?.textContent ?? "";
  if (!text.includes("Please try a different approach")) throw new Error("nudge did not prefill the real composer");
  if (!text.includes(existingDraft)) throw new Error("nudge replaced the existing draft");
  const field = ctx.document.querySelector<HTMLElement>(editor)!;
  if (ctx.document.activeElement !== field && !field.contains(ctx.document.activeElement))
    throw new Error("nudge did not focus the real composer editor");
  // The shell gallery's synthetic key events do not perform the browser's default caret movement.
  // Place the caret after the prefilled draft, then use the real editor's typing path below.
  const selection = field.ownerDocument.defaultView!.getSelection();
  const range = field.ownerDocument.createRange();
  range.selectNodeContents(field);
  range.collapse(false);
  selection?.removeAllRanges();
  selection?.addRange(range);
  await ctx.type(" Check the smaller auth fixture first.", { selector: editor });
  // Typing can grow the field on its existing spring. Finish that bounded motion
  // before measuring the independent attention-clear transition.
  await ctx.waitFor(
    () =>
      !ctx.document
        .querySelector(box)!
        .getAnimations({ subtree: true })
        .some((animation) => animation.playState === "running" || animation.pending),
    { capMs: 2000 },
  );
  if (
    !ctx.document.querySelector(editor)?.textContent?.includes("smaller auth fixture") ||
    !ctx.document.querySelector(editor)?.textContent?.includes(existingDraft)
  )
    throw new Error("the nudge draft cannot be edited");
  if (log.slice(callsBefore).some(({ method }) => method === "chat.send" || method === "chat.cancel"))
    throw new Error("the nudge sent or cancelled the agent");
  if (!ctx.document.querySelector(".acpmux-main[data-stuck]")) throw new Error("nudge cleared attention");
};

const clearOnProgress = async (ctx: PlayContext) => {
  await editNudge(ctx);
  const before = bounds(ctx);
  bridge(ctx).receive(structuredClone(progressed));
  await ctx.waitFor(() => !ctx.document.querySelector(".acpmux-main[data-stuck], .acpmux-stuck-banner"));
  unchanged(before, bounds(ctx));
  if (
    !ctx.document.querySelector(editor)?.textContent?.includes("smaller auth fixture") ||
    !ctx.document.querySelector(editor)?.textContent?.includes("Check the auth regression too.")
  )
    throw new Error("progress cleared the person's draft");
};

const nudgeChecks = {
  layoutShiftMax: {
    value: 0.05,
    reason:
      "Prefilling the multiline hint grows the composer like typing; play asserts its fixed bottom edge and matching banner movement. Attention transitions themselves keep identical geometry.",
  },
};

export default agentPaneEntry({
  id: "agent-pane.stuck-attention",
  title: "Stuck agent attention in a chat",
  area: "Agent pane",
  height: 620,
  widths: { narrow: 420, normal: 720, wide: 1000 },
  covers: ["agent-session/acpmux/App.tsx", "agent-session/acpmux/StuckBanner.tsx#StuckBanner"],
  variants: {
    "loop-ring": {
      note: "The running chat carries one amber pane ring and the repeated-call diagnosis.",
      snapshot: loop,
      play: liveAttention,
    },
    "silent-ring": {
      note: "Existing daemon silence appears through the same calm attention treatment.",
      snapshot: silent,
      play: liveAttention,
    },
    "nudge-edit": {
      note: "Nudge pre-fills the real composer and remains editable; it neither sends nor cancels the agent.",
      snapshot: loop,
      play: editNudge,
      checks: nudgeChecks,
    },
    "clears-on-progress": {
      note: "Progress removes the ring and diagnosis without moving the composer or deleting an edited draft.",
      snapshot: loop,
      play: clearOnProgress,
      checks: nudgeChecks,
    },
    "attention-transition": {
      note: "A live episode arrives through the bridge with no composer geometry change.",
      snapshot: base,
      play: async (ctx) => {
        const before = bounds(ctx);
        bridge(ctx).receive(structuredClone(loop));
        await liveAttention(ctx);
        unchanged(before, bounds(ctx));
      },
    },
    "quick-loop-ring": {
      note: "The same loop attention and ring appear on the Quick Composer chat surface.",
      ready: { surface: "quick" },
      snapshot: loop,
      play: quickAttention,
    },
  },
});
