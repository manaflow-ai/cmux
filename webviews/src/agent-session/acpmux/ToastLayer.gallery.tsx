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
//
// Toasts v2 (ui/toastsV2.experiment.ts; Leo 2026-11-19: "Promise toasts with Undo"): `promise-*`
// is one toast for one piece of work (working, success, error, and `promise-play` running working
// to success in place), `undo-*` the one-line toasts closing a tab or archiving a session leave.
// Each is drawn in today's look and pinned to each v2 arm (`-mark`, `-tinted`, `-accent-bar`), and
// the bare variants take the arm from the compare view.
//
// Move to Cloud's working toast (`move-*`; native, CloudMove.swift, drawn here in the same deck):
// its headline, then Rust's line (cmux-tui moves/progress.rs), word for word from its tests: a step
// is named from the click on, and a step past its usual time keeps a clock of how long it has run
// (Leo, 2026-11-23: "you guys need to be absolutely exhaustively testing out what would a new user
// be seeing here?").
import { useEffect, useMemo, useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import { createNoticeQueue, type NoticeQueue, type StackLayout, type ToastSpec } from "../../ui/NoticeStack";
import type { Anchor } from "../../ui/anchors";
import type { DeckAlign, DragFeel } from "../../ui/NoticeDeck";
import { toastsV2, type ToastLook } from "../../ui/toastsV2.experiment";
import { ToastLayer } from "./ToastLayer";

type Toasts =
  | "single"
  | "stack"
  | "count"
  | "persistent"
  | "promise-working"
  | "promise-success"
  | "promise-error"
  | "promise-play"
  | "undo-close-tab"
  | "undo-archive"
  | "move-start"
  | "move-copy"
  | "move-longer";
type Props = {
  toasts: Toasts;
  layout?: StackLayout;
  align?: DeckAlign;
  placement?: Anchor;
  drag?: DragFeel;
  /** Pins a toasts-v2 arm; without it the compare view's arm (or the default) draws. */
  look?: ToastLook;
};

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
  // Drawn by `queue.promise` below.
  "promise-working": [],
  "promise-success": [],
  "promise-error": [],
  "promise-play": [],
  "undo-close-tab": [{ message: "Closed “Build logs”", actions: [{ id: "undo", label: "Undo", onSelect: noop }] }],
  "undo-archive": [{ message: "Archived “Fix login race”", actions: [{ id: "undo", label: "Undo", onSelect: noop }] }],
  "move-start": [moving("1 of 5 · Checking the folder · about 40 s left")],
  "move-copy": [moving("3 of 5 · Copying the folder (1,204 files) · about 45 s left")],
  "move-longer": [
    moving("4 of 5 · Handing the agent to dev · taking longer than usual, 1 min so far (usually about 10 s)"),
  ],
};

/** Move to Cloud's working toast with `line`, Rust's words for the step it is on. */
function moving(line: string): ToastSpec {
  return { id: "cloud-move", state: "working", title: "Moving this chat to Cloud…", message: line };
}

/** The play's signal that the promise variant's work is done. */
const FINISH_EVENT = "toast-gallery-finish";

const ROWS = [
  "Why does the relay fall over after a deploy?",
  "The relay keeps its sessions in memory, so a deploy drops every socket at once. Each client then retries on the same schedule, and the burst lands on one instance before the others are ready.",
  "Spread the retries with jitter, and let the new instance take traffic only after it reports ready.",
  "I agree on both, and I've passed them along.",
];

function ToastLayerGallery({ toasts, layout = "stacked", align = "center", placement = "bottom", drag, look }: Props) {
  // The promise variants' work: settled at once for a result, never for `working`, and by the
  // play's finish event for `promise-play`.
  const work = useMemo(() => {
    let finish: () => void = noop;
    const promise =
      toasts === "promise-success"
        ? Promise.resolve()
        : toasts === "promise-error"
          ? Promise.reject(new Error("3 failed"))
          : new Promise<void>((resolve) => {
              finish = () => resolve();
            });
    return { promise, finish };
  }, [toasts]);
  const queue: NoticeQueue = useMemo(() => {
    const made = createNoticeQueue();
    // The gallery holds them: nothing times out under a capture.
    for (const spec of FIXTURES[toasts]) made.show({ duration: 0, anchor: placement, ...spec });
    if (toasts.startsWith("promise-")) {
      const hold = { duration: 0, anchor: placement };
      made.promise(
        "tests",
        {
          loading: { ...hold, message: "Running tests…" },
          success: { ...hold, message: "128 tests passed." },
          error: {
            ...hold,
            title: "Tests failed",
            message: "3 of 128 failed in auth.spec.ts.",
            retry: { label: "Retry", onRetry: noop },
          },
        },
        work.promise,
      );
    }
    return made;
  }, [toasts, placement, work]);
  useEffect(() => {
    const finish = () => work.finish();
    document.addEventListener(FINISH_EVENT, finish);
    return () => document.removeEventListener(FINISH_EVENT, finish);
  }, [work]);
  const [top, setTop] = useState<HTMLDivElement | null>(null);
  return (
    <div className="acpmux-shell toast-gallery" data-promise-play={toasts === "promise-play" ? "" : undefined}>
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
          <ToastLayer queue={queue} topHost={top} layout={layout} align={align} drag={drag} look={look} />
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

// The promise toast's one change: working, then the same card turns into its success in place.
const finishWork: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector('.ui-notice[data-state="working"]'));
  ctx.document.dispatchEvent(new CustomEvent(FINISH_EVENT));
  await ctx.waitFor(
    () =>
      ctx.document.querySelectorAll(".ui-notice").length === 1 &&
      ctx.document.querySelector('.ui-notice[data-state="success"]'),
  );
};

// A toast is up in the arm's look (the compare script for every v2 variant but the play).
const toastUp: Play = async (ctx) => {
  await ctx.waitFor(() => ctx.document.querySelector(".ui-notice-deck-card[data-front] .ui-notice"));
};

const V2_STATES = {
  "promise-working": "A promise toast while its work runs: spinner, no timeout.",
  "promise-success": "The promise toast's success, in the same card.",
  "promise-error": "The promise toast's error, in the same card, Retry first.",
  "undo-close-tab": "Closing a tab: one line, Undo at the trailing edge.",
  "undo-archive": "Archiving a session: one line, Undo at the trailing edge.",
} as const satisfies Partial<Record<Toasts, string>>;
const V2_ARMS: Record<Exclude<ToastLook, "off">, string> = {
  mark: "Recommended arm `mark`",
  tinted: "Arm `tinted` (conflicts with never-red-slabs)",
  "accent-bar": "Arm `accent-bar`",
};
const v2Variants: Record<string, { props: Props; note: string; play?: Play }> = {};
for (const [toasts, note] of Object.entries(V2_STATES) as [keyof typeof V2_STATES, string][]) {
  v2Variants[toasts] = { props: { toasts }, note: `${note} Today's look (arm off); compare for the others.` };
  for (const [look, arm] of Object.entries(V2_ARMS) as [Exclude<ToastLook, "off">, string][])
    v2Variants[`${toasts}-${look}`] = { props: { toasts, look }, note: `${arm}: ${note}` };
}
v2Variants["promise-play"] = {
  props: { toasts: "promise-play" },
  play: finishWork,
  note: "Working → success in place: one card, no new toast, no jump.",
};
v2Variants["promise-play-mark"] = {
  props: { toasts: "promise-play", look: "mark" },
  play: finishWork,
  note: "Recommended arm `mark`: working → success in place.",
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
    "move-start": {
      props: { toasts: "move-start" },
      note: "Move to Cloud, just clicked: the first step is named at once, with about how long is left.",
    },
    "move-copy": {
      props: { toasts: "move-copy" },
      note: "Move to Cloud, about 20 s in: copying the folder, its file count and a measured countdown.",
    },
    "move-longer": {
      props: { toasts: "move-longer" },
      note: "Move to Cloud past a step's usual time: it says so and keeps a clock of the time so far.",
    },
    ...v2Variants,
  },
  // Toasts v2 (Leo 2026-11-19, promise toasts with Undo): open a `promise-*` or `undo-*` variant
  // in view `compare`. On `promise-play` the script finishes the work; elsewhere it shows the toast.
  experiment: {
    definition: toastsV2,
    script: [
      {
        name: "Finish the work, or show the toast",
        run: async (ctx) => {
          if (ctx.document.querySelector(".toast-gallery[data-promise-play]")) await finishWork(ctx);
          else await toastUp(ctx);
        },
      },
    ],
  },
});
