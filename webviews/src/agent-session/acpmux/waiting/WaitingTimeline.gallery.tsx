// l10n-allow-file: gallery fixture labels and session titles, not shipped UI.
//
// Waiting on me sits on a new chat's home, under the inbox: one lane per agent chat active today,
// working in muted green, waiting on the person in red, and the day's total wait in red on top. A
// red stretch opens its chat at the turn the wait began in. The three looks (bars, the home's;
// ribbon; heat) are variants, with the empty, one-chat and 50-chat days.
import { useState, type ComponentProps } from "react";
import { componentEntry } from "../../../gallery/format";
import { GALLERY_NOW, minutesAgo } from "../../../gallery/clock";
import { chat, session } from "../../../gallery/fixtures/acpmux";
import type { Play } from "../../../gallery/play";
import { Composer } from "../Composer";
import { EmptyState } from "../EmptyState";
import { WaitingTimeline } from "./WaitingTimeline";
import { localMidnight, type WaitingDay, type WaitingLane, type WaitingSpan } from "./waitingModel";

type Props = ComponentProps<typeof WaitingTimeline>;

const SINCE = localMidnight(GALLERY_NOW);

const TITLES = [
  "Fix the checkout page",
  "Investigate the build cache",
  "Settings sign-in",
  "Release notes",
  "Polish the sidebar",
  "Migrate the billing table",
  "Flaky upload test",
  "Dark mode contrast",
];

/// A chat's day from its status changes: `[minutesAgo, state]` pairs, oldest first, each lasting
/// until the next; the last one ends `end` minutes ago (0: still open at now).
function lane(sessionId: string, changes: [number, WaitingSpan["state"] | "idle"][], end = 0): WaitingLane {
  const spans: WaitingSpan[] = [];
  changes.forEach(([ago, state], index) => {
    const until = index + 1 < changes.length ? changes[index + 1][0] : end;
    if (state === "idle") return;
    spans.push({
      state,
      start: minutesAgo(ago),
      end: minutesAgo(until),
      seq: 10 + index,
      turnId: `${sessionId}-t${index}`,
    });
  });
  const sum = (state: WaitingSpan["state"]) =>
    spans.filter((span) => span.state === state).reduce((total, span) => total + span.end - span.start, 0);
  return { sessionId, workingMs: sum("working"), blockedMs: sum("blocked"), lastAt: spans.at(-1)?.end ?? SINCE, spans };
}

function day(lanes: WaitingLane[]): WaitingDay {
  const sorted = [...lanes].sort((a, b) => b.blockedMs - a.blockedMs || b.lastAt - a.lastAt);
  return {
    since: SINCE,
    until: GALLERY_NOW,
    workingMs: lanes.reduce((total, item) => total + item.workingMs, 0),
    blockedMs: lanes.reduce((total, item) => total + item.blockedMs, 0),
    lanes: sorted,
  };
}

const morning = day([
  lane("wait-checkout", [
    [150, "working"],
    [128, "blocked"],
    [96, "working"],
    [70, "idle"],
    [52, "working"],
    [40, "blocked"],
  ]),
  lane(
    "wait-cache",
    [
      [140, "working"],
      [110, "blocked"],
      [104, "working"],
      [61, "blocked"],
      [33, "working"],
    ],
    12,
  ),
  lane("wait-auth", [
    [90, "working"],
    [84, "blocked"],
    [83, "working"],
    [58, "idle"],
    [20, "working"],
  ]),
  lane(
    "wait-notes",
    [
      [120, "working"],
      [100, "idle"],
      [45, "working"],
      [44, "blocked"],
      [43, "working"],
    ],
    30,
  ),
  lane("wait-sidebar", [[75, "working"]], 5),
]);

const sessionsFor = (lanes: readonly WaitingLane[]) =>
  lanes.map((item, index) =>
    session({
      sessionId: item.sessionId,
      title:
        TITLES[index % TITLES.length] + (index >= TITLES.length ? ` ${Math.floor(index / TITLES.length) + 1}` : ""),
      status:
        item.spans.at(-1)?.end === GALLERY_NOW
          ? item.spans.at(-1)?.state === "blocked"
            ? "waiting"
            : "running"
          : "ready",
      updatedAt: item.lastAt,
    }),
  );

/// 50 chats, each with a few hundred status changes, to show the lanes stay windowed.
const busy = day(
  Array.from({ length: 50 }, (_, index) => {
    const changes: [number, WaitingSpan["state"] | "idle"][] = [];
    // A fixed pattern per chat: work, a short wait now and then, a long one for every seventh chat.
    for (let at = 560 - index * 3, step = 0; at > 4; step++) {
      const state: WaitingSpan["state"] | "idle" = step % 3 === 0 ? "working" : step % 3 === 1 ? "blocked" : "idle";
      changes.push([at, state]);
      at -= state === "blocked" ? (index % 7 === 0 ? 25 : 1 + (step % 4)) : 6 + ((index + step) % 9);
    }
    return lane(`busy-${index}`, changes);
  }),
);

const oneChat = day([
  lane("wait-checkout", [
    [80, "working"],
    [62, "blocked"],
    [21, "working"],
  ]),
]);

const calm = day([
  lane(
    "wait-checkout",
    [
      [200, "working"],
      [120, "idle"],
      [60, "working"],
    ],
    10,
  ),
  lane("wait-cache", [[90, "working"]], 40),
]);

const props = (value: WaitingDay, look?: Props["look"]): Props => ({
  day: value,
  sessions: sessionsFor(value.lanes),
  onJump: () => undefined,
  look,
});

const newChat = chat([], { title: "New chat" });
const NoChips = () => null;

/// The new chat's frame (App.tsx): the hero, then the home area over the real composer.
function withReceipt(Component: typeof WaitingTimeline) {
  return function GalleryWaitingTimeline(given: Props) {
    const [jumped, setJumped] = useState<string>();
    return (
      <section className="acpmux-shell waiting-gallery" aria-label={newChat.summary?.title} data-jump={jumped ?? ""}>
        <div className="acpmux-main" data-new-chat="">
          <div className="acpmux-stage">
            <EmptyState project="atlas-web" />
          </div>
          <div className="acpmux-dock">
            <div className="acpmux-home-area">
              <Component
                {...given}
                onJump={(sessionId, turnId) => {
                  given.onJump(sessionId, turnId);
                  setJumped(`${sessionId}:${turnId ?? ""}`);
                }}
              />
            </div>
            <Composer snapshot={newChat} chips={NoChips} onSend={() => true} onStop={() => undefined} />
          </div>
        </div>
      </section>
    );
  };
}

const jump: Play = async (ctx) => {
  await ctx.click({ role: "button", name: /^Fix the checkout page: Waited on you/ });
  await ctx.waitFor(() =>
    (ctx.document.querySelector(".waiting-gallery")?.getAttribute("data-jump") ?? "").startsWith("wait-checkout:"),
  );
};

const scrollLanes: Play = async (ctx) => {
  await ctx.scroll({ selector: ".acpmux-waiting-scroll" }, "bottom");
  await ctx.waitFor(() => Boolean(ctx.document.querySelector(".acpmux-waiting-row[style*='--waiting-index: 49']")));
};

export default componentEntry<Props>({
  id: "agent-pane.waiting-timeline",
  title: "Waiting on me",
  area: "Agent pane",
  pane: true,
  height: 640,
  widths: { narrow: 360, normal: 560, wide: 760 },
  anchors: [{ selector: ".waiting-gallery" }],
  covers: ["agent-session/acpmux/waiting/WaitingTimeline.tsx"],
  styles: () => import("../styles.css"),
  checks: {
    layoutShiftMax: {
      value: 0,
      reason: "Scrolling the lanes or pressing a wait must not move the home or the composer.",
    },
    longFrameFailMs: {
      value: 33,
      reason: "Only the rows in the scroll window are mounted, so 50 chats draw within one frame.",
    },
  },
  load: () => import("./WaitingTimeline").then(({ WaitingTimeline: Component }) => withReceipt(Component)),
  variants: {
    bars: {
      note: "The home's look: a title column, each lane's bar, and its waited time. Agents waited 1 h 42 m on you today, in red; a red stretch opens its chat at that turn.",
      props: props(morning, "bars"),
      play: jump,
    },
    ribbon: {
      note: "The title over a thin ribbon across the whole row, for a narrow pane; no per-lane totals.",
      props: props(morning, "ribbon"),
    },
    heat: {
      note: "Working time faint grey, so only the waits stand out.",
      props: props(morning, "heat"),
    },
    "no-waits": {
      note: "Agents worked today and never waited: a calm line, not red.",
      props: props(calm),
    },
    "one-chat": {
      note: "One chat, waiting 41 minutes before it went on.",
      props: props(oneChat),
    },
    "fifty-chats": {
      note: "50 chats with hundreds of status changes each: six rows show, only the rows in view are mounted, and short waits join into one stretch.",
      props: props(busy),
      play: scrollLanes,
    },
    "empty-day": {
      note: "No chat was active today: the section draws nothing.",
      props: props(day([])),
    },
  },
});
