// l10n-allow-file: gallery fixtures, not shipped UI.
// The agent pane's toasts (ToastLayer.tsx, ui/NoticeDeck.tsx, ui/anchors.ts) over a chat's foot,
// above a docked composer: each state the deck has, each placement compared, and three feels of
// the drag that moves a toast between the six anchors.
//
// Picked and shipped: `stacked` at the bottom centre, on the composer's column. It sits where the
// person reads (the composer and the newest streamed text), it covers the fewest transcript rows
// (one card tall however many toasts are up), and it spreads on hover so every toast can still be
// read and answered. `list` (every toast in full, newest at the bottom) covers three cards' worth
// of the newest rows; `end` (the deck at the trailing edge) leaves the reading column clear but is
// off the eye's line, and in a narrow pane is the same as centred; `top` is the first thing read
// when the pane opens but nowhere near where the person looks while a reply streams (Leo,
// 2026-11-07, on toasts at the top: "Is this a weather report?"). A person who wants a kind of
// toast up there drags it there once, and that kind shows there after.
//
// Drag feel, picked and shipped: `ghosts`. The toast follows the pointer one to one and settles on
// the shared spring, and while it is held the six anchors are outlined with the one it would
// settle at lit, so the snap is never a surprise. `spring` is the same without the outlines (the
// snap lands somewhere the person could not see coming); `rubber` leans the toast toward that
// anchor as it moves, which tells the same thing but makes the toast lag the pointer.
import { useMemo, useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { createNoticeQueue, type NoticeQueue, type StackLayout, type ToastSpec } from "../../ui/NoticeStack";
import type { Anchor } from "../../ui/anchors";
import type { DeckAlign, DragFeel } from "../../ui/NoticeDeck";
import { ToastLayer } from "./ToastLayer";

type Toasts = "single" | "stack" | "count" | "persistent";
type Props = { toasts: Toasts; layout?: StackLayout; align?: DeckAlign; placement?: Anchor; drag?: DragFeel };

const noop = () => undefined;
const FIXTURES: Record<Toasts, ToastSpec[]> = {
  single: [{ message: "Can't find build-box/mux-rs's chat" }],
  stack: [
    { message: "Copied the link." },
    { message: "Move to Cloud wasn't run. Try again from the chat's menu." },
    { message: "Can't find build-box/mux-rs's chat" },
  ],
  count: [{ message: "Can't find build-box/mux-rs's chat" }, { message: "Can't find build-box/mux-rs's chat" }],
  persistent: [
    { message: "Copied the link." },
    {
      message: "Archived 3 chats.",
      duration: 0,
      actions: [{ id: "undo", label: "Undo", onSelect: noop }],
    },
  ],
};

const ROWS = [
  "Why does the relay fall over after a deploy?",
  "The relay keeps its sessions in memory, so a deploy drops every socket at once. Each client then retries on the same schedule, and the burst lands on one instance before the others are ready.",
  "Spread the retries with jitter, and let the new instance take traffic only after it reports ready.",
  "I agree on both, and I've passed them along.",
];

function ToastLayerGallery({ toasts, layout = "stacked", align = "center", placement = "bottom", drag }: Props) {
  const queue: NoticeQueue = useMemo(() => {
    const made = createNoticeQueue();
    // The gallery holds them: nothing times out under a capture.
    for (const spec of FIXTURES[toasts]) made.show({ duration: 0, anchor: placement, ...spec });
    return made;
  }, [toasts, placement]);
  const [top, setTop] = useState<HTMLDivElement | null>(null);
  return (
    <div className="acpmux-shell toast-gallery">
      <div className="acpmux-main" data-dock="float">
        <div ref={setTop} className="acpmux-toasts-top" />
        <div className="acpmux-stage toast-gallery-stage">
          {ROWS.map((row) => (
            <p key={row} className="toast-gallery-row">
              {row}
            </p>
          ))}
        </div>
        <div className="acpmux-dock">
          <ToastLayer queue={queue} topHost={top} layout={layout} align={align} drag={drag} />
          <div className="acpmux-composer">
            <div className="acpmux-composer-box ui-glass toast-gallery-composer">Ask for follow-up changes</div>
          </div>
        </div>
      </div>
    </div>
  );
}

// Held mid-drag over the chat's top rows: the anchor outlines show, the top one lit.
const holding: Play = async (ctx) => {
  await ctx.pointer.down({ selector: ".ui-notice-deck-card[data-front]" });
  await ctx.pointer.move({ selector: ".toast-gallery-row" });
  await ctx.waitFor(() => ctx.document.querySelector(".ui-notice-deck-card[data-dragging]"));
};

const spread: Play = async (ctx) => {
  await ctx.hover({ selector: ".ui-notice-deck-card[data-front]" });
  await ctx.waitFor(() => ctx.document.querySelector(".ui-notice-deck[data-expanded]"));
};

export default componentEntry<Props>({
  id: "agent-pane.toasts",
  title: "Pane toasts",
  area: "Agent pane",
  height: 420,
  pane: true,
  covers: ["agent-session/acpmux/ToastLayer.tsx", "ui/NoticeDeck.tsx"],
  keywords: ["toast", "notice", "stack", "deck", "drag", "anchor"],
  load: async () => ToastLayerGallery,
  styles: () =>
    Promise.all([
      import("./styles.css"),
      import("./bottomStack.css"),
      import("../../ui/ui.css"),
      import("./ToastLayer.gallery.css"),
    ]),
  variants: {
    single: { props: { toasts: "single" }, note: "One toast over the chat's foot, above the composer." },
    stacked: {
      props: { toasts: "stack" },
      note: "Shipped: three toasts gathered, newest in front, two edges peeking above it.",
    },
    "stacked-hover": {
      props: { toasts: "stack" },
      play: spread,
      note: "Hovered: the deck spreads into the full list; the time of each stops.",
    },
    count: { props: { toasts: "count" }, note: "The same toast twice: one card with a count." },
    persistent: {
      props: { toasts: "persistent" },
      play: spread,
      note: "A persistent toast with Undo stays until answered or closed, spread here.",
    },
    list: { props: { toasts: "stack", layout: "list" }, note: "Option: every toast in full, newest at the bottom." },
    end: { props: { toasts: "stack", align: "end" }, note: "Option: the deck at the trailing edge." },
    top: { props: { toasts: "stack", placement: "top" }, note: "Option: at the top of the chat. Not picked." },
    "drag-ghosts": {
      props: { toasts: "stack", drag: "ghosts" },
      play: holding,
      note: "Shipped drag: one to one, the six anchors outlined while held, settles on the spring.",
    },
    "drag-spring": {
      props: { toasts: "stack", drag: "spring" },
      play: holding,
      note: "Option: the same drag, no outlines.",
    },
    "drag-rubber": {
      props: { toasts: "stack", drag: "rubber" },
      play: holding,
      note: "Option: the held toast leans toward the anchor it would settle at.",
    },
    "top-right": {
      props: { toasts: "count", placement: "top-right", drag: "ghosts" },
      note: "A kind of toast dragged to the top right once shows there after.",
    },
  },
});
