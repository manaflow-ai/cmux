// l10n-allow-file: gallery fixtures (sample prompts, senders and replies), not shipped UI.
import { agentPaneEntry } from "../../../gallery/format";
import type { PlayContext } from "../../../gallery/play";
import { assistant, chat, summary, user } from "../../../gallery/fixtures/acpmux";
import { incomingPrompt } from "../conversation/incomingMessage";

// The prompt rail's foot and its preview card in the whole pane, composer included (Leo, 2026-11-03:
// "this left scroll rail prob goes a little bit too far down now and also the hover previews are
// offset strangely"). The rail ends above the bottom stack and clear of the transcript's bottom fade,
// and the card centers on its tick, kept only inside the view the stack leaves. Both read one foot:
// the stack's top (VirtualTranscript `railBox.live`). A long chat, so the rail scrolls and the band
// sits at its foot, with runs of other chats' messages folded into one tick (#32916), one near the
// foot. Synthetic prompts and senders only.
const message = (seq: number, minutes: number) => {
  const text = `Status ${seq}: the helper's branch is green and the review passed.`;
  const incoming = incomingPrompt(text, {
    _meta: { provenance: { kind: "session_message", from: "helper-id", fromName: "lane-box-1/helper", to: "me" } },
  });
  return incoming?.kind === "message"
    ? user(incoming.message.text, minutes, { id: `user-${seq}`, incoming, resend: text })
    : user(text, minutes, { id: `user-${seq}` });
};
/// Seventy messages: the person's prompts, with three-message runs from another chat at 30 and 64.
const rows = Array.from({ length: 70 }, (_, index) => {
  const seq = index * 3 + 1;
  const minutes = 400 - index * 2;
  const folded = (index >= 30 && index < 33) || (index >= 64 && index < 67);
  return [
    folded
      ? message(seq, minutes)
      : user(`Prompt ${index + 1}: check the next part of the plan`, minutes, { id: `user-${seq}` }),
    assistant(`Part ${index + 1} checked.\n\nA second paragraph so the turn has some height.`, minutes - 0.2),
    summary(minutes - 0.4, { status: "completed" }),
  ];
}).flat();

/// The rail's last drawn tick (the band's foot at the chat's end), as a selector.
const lastTick = (ctx: PlayContext) => {
  const drawn = [...ctx.document.querySelectorAll<HTMLElement>(".acpmux-minimap__list [data-tick]")];
  return `.acpmux-minimap__list [data-tick="${Math.max(...drawn.map((tick) => Number(tick.dataset.tick)))}"]`;
};
const railReady = (ctx: PlayContext) =>
  ctx.waitFor(() => ctx.document.querySelector(".acpmux-minimap__list [data-tick]"));
/// A one-tab pane: the transcript runs up under its floating tab row (header/tabRow.ts `soloTab`).
const solo = async (ctx: PlayContext) => {
  const { setTabRow } = await import("../header/tabRow");
  setTabRow({ height: 38, trailingInset: 0, soloTab: true });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-stage[data-solo-tab] .acpmux-minimap__rail"));
};
/// Eight lines typed into the composer after the rail drew at rest: the stack grows over the view.
const tallDraft = async (ctx: PlayContext) => {
  const prompt = { selector: ".acpmux-composer-prompt [contenteditable]" };
  await ctx.type("Line 1 of a long draft", prompt);
  for (let line = 2; line <= 8; line++) {
    await ctx.press("Shift+Enter");
    await ctx.type(`Line ${line} of a long draft`, prompt);
  }
};
const hoverLast = (ctx: PlayContext) => ctx.hover({ selector: lastTick(ctx) });

export default agentPaneEntry({
  id: "agent-pane.thread-minimap-foot",
  title: "Prompt rail foot and preview card",
  area: "Agent pane",
  height: 720,
  widths: { narrow: 880, normal: 1040, wide: 1240 },
  anchors: [{ selector: ".acpmux-scroll" }],
  covers: [
    "agent-session/acpmux/threadMinimap/ThreadMinimap.tsx#ThreadMinimap",
    "agent-session/acpmux/threadMinimap/PreviewCard.tsx#PreviewCard",
  ],
  variants: {
    resting: {
      note: "A long chat at its end: the rail's last tick sits clear of the bottom fade, above the composer.",
      snapshot: chat(rows, { title: "Prompt rail foot" }),
      play: railReady,
    },
    "bottom-hovered": {
      note: "The last tick hovered: the card centers on it as far as the view above the composer lets it, never higher.",
      snapshot: chat(rows, { title: "Prompt rail foot, last tick hovered" }),
      play: async (ctx) => {
        await railReady(ctx);
        await hoverLast(ctx);
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-minimap__card"));
      },
    },
    "tall-draft": {
      note: "Eight composer lines typed after the rail drew: its top stays where it was and its foot rises above the grown stack (the list scrolls), so no tick runs under the composer.",
      snapshot: chat(rows, { title: "Prompt rail over a tall draft" }),
      play: async (ctx) => {
        await railReady(ctx);
        await tallDraft(ctx);
        await hoverLast(ctx);
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-minimap__card"));
      },
    },
    "solo-tab-hovered": {
      note: "A one-tab pane, the transcript under its floating tab row: the rail and its card read the same foot, so the last tick's card still meets it.",
      snapshot: chat(rows, { title: "Prompt rail in a one-tab pane" }),
      play: async (ctx) => {
        await solo(ctx);
        await railReady(ctx);
        await hoverLast(ctx);
        await ctx.waitFor(() => ctx.document.querySelector(".acpmux-minimap__card"));
      },
    },
  },
});
