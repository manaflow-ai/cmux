// l10n-allow-file: gallery fixture labels and session titles, not shipped UI.
//
// HomeLists is the welcome surface between the hero and the composer. Its most important
// contract is easy to lose in the full pane: only other, listed sessions appear; waiting sessions
// and open review-ready pull requests have independent three-row caps; each row is a real button.
import { useState, type ComponentProps } from "react";
import { componentEntry } from "../../gallery/format";
import { minutesAgo } from "../../gallery/clock";
import { session } from "../../gallery/fixtures/acpmux";
import type { Play } from "../../gallery/play";
import { HomeLists } from "./HomeLists";

type Props = ComponentProps<typeof HomeLists>;

const inputSessions = [
  session({
    sessionId: "home-input-checkout",
    title: "Fix the checkout page",
    status: "waiting",
    updatedAt: minutesAgo(2),
    preview: "The payment form needs your answer.",
  }),
  session({
    sessionId: "home-input-cache",
    title: "Investigate the build cache",
    pendingPermissions: 1,
    updatedAt: minutesAgo(5),
    preview: "The runner is waiting for permission.",
  }),
];

const reviewSessions = [
  session({
    sessionId: "home-review-sidebar",
    title: "Polish the sidebar",
    updatedAt: minutesAgo(1),
    pullRequest: { number: 19031, title: "Polish the sidebar", state: "open", reviewReady: true },
  }),
  session({
    sessionId: "home-review-cache",
    title: "Make cache misses visible",
    updatedAt: minutesAgo(4),
    pullRequest: { number: 19032, title: "Make cache misses visible", state: "open", reviewReady: true },
  }),
];

const current = session({
  sessionId: "home-current",
  title: "The current chat",
  status: "waiting",
  updatedAt: minutesAgo(0),
});
const hidden = [
  session({ sessionId: "home-archived", title: "An archived chat", status: "waiting", archived: true }),
  session({ sessionId: "home-side", title: "A side chat", status: "waiting", side: true }),
  session({
    sessionId: "home-draft",
    title: "A draft pull request",
    pullRequest: { number: 19033, title: "A draft pull request", state: "draft", reviewReady: true },
  }),
  session({
    sessionId: "home-not-ready",
    title: "Checks still running",
    pullRequest: { number: 19034, title: "Checks still running", state: "open", reviewReady: false },
  }),
];

const baseline: Props = {
  sessions: [...inputSessions, ...reviewSessions, current, ...hidden],
  currentId: current.sessionId,
  onSelect: () => undefined,
};

const empty: Props = {
  sessions: [current, ...hidden],
  currentId: current.sessionId,
  onSelect: () => undefined,
};

const cappedInput = Array.from({ length: 5 }, (_, index) =>
  session({
    sessionId: `home-cap-input-${index + 1}`,
    title: `Waiting session ${index + 1}`,
    status: "waiting",
    updatedAt: minutesAgo(index + 1),
  }),
);
const cappedReview = Array.from({ length: 5 }, (_, index) =>
  session({
    sessionId: `home-cap-review-${index + 1}`,
    title: `Review session ${index + 1}`,
    updatedAt: minutesAgo(index + 1),
    pullRequest: {
      number: 19040 + index,
      title: `Review session ${index + 1}`,
      state: "open",
      reviewReady: true,
    },
  }),
);

const capped: Props = {
  sessions: [...cappedInput, ...cappedReview, ...hidden],
  currentId: current.sessionId,
  onSelect: () => undefined,
};

function withReceipt(Component: typeof HomeLists) {
  return function GalleryHomeLists(props: Props) {
    const [selected, setSelected] = useState<string>();
    return (
      <div className="home-lists-gallery" data-home-selection={selected ?? ""}>
        <Component
          {...props}
          onSelect={(sessionId) => {
            props.onSelect(sessionId);
            setSelected(sessionId);
          }}
        />
      </div>
    );
  };
}

const click: Play = async (ctx) => {
  await ctx.click({ role: "button", name: /Polish the sidebar/ });
  await ctx.waitFor(
    () =>
      ctx.document.querySelector(".home-lists-gallery")?.getAttribute("data-home-selection") === "home-review-sidebar",
  );
};

const keyboard: Play = async (ctx) => {
  await ctx.focus({ role: "button", name: /Fix the checkout page/ });
  await ctx.press("Enter");
  await ctx.waitFor(
    () =>
      ctx.document.querySelector(".home-lists-gallery")?.getAttribute("data-home-selection") === "home-input-checkout",
  );
  await ctx.focus({ role: "button", name: /Investigate the build cache/ });
  await ctx.press(" ");
  await ctx.waitFor(
    () => ctx.document.querySelector(".home-lists-gallery")?.getAttribute("data-home-selection") === "home-input-cache",
  );
};

export default componentEntry<Props>({
  id: "agent-pane.home-lists",
  title: "Home session lists",
  area: "Agent pane",
  height: 360,
  widths: { narrow: 360, normal: 560, wide: 760 },
  anchors: [{ selector: ".home-lists-gallery" }],
  covers: ["agent-session/acpmux/HomeLists.tsx#HomeLists"],
  styles: () => import("./styles.css"),
  checks: {
    anchorMovePx: {
      value: 0,
      reason: "Opening a home row must preserve the welcome list's geometry until the host switches sessions.",
    },
    layoutShiftMax: {
      value: 0,
      reason: "Filtering and capping home rows must not reflow the surrounding home/composer surface.",
    },
    longFrameFailMs: {
      value: 33,
      reason: "Home rows are direct local buttons and should respond within one display frame.",
    },
    settleMaxMs: {
      value: 250,
      reason: "Activating a home row is a local button interaction and should settle within a quarter second.",
    },
  },
  load: () => import("./HomeLists").then(({ HomeLists: Component }) => withReceipt(Component)),
  variants: {
    baseline: {
      note: "Needs input and Ready for review stay separate, while the current, archived, side and not-ready chats stay out.",
      props: baseline,
    },
    empty: {
      note: "A clean new chat has no home lists when every other session is current, archived, side, or not ready.",
      props: empty,
    },
    "cap-filter": {
      note: "Each list caps at three newest rows; older rows and sessions excluded by the home contract never appear.",
      props: capped,
    },
    click: {
      note: "Clicking a review row dispatches its session id to the host.",
      props: baseline,
      play: click,
    },
    keyboard: {
      note: "Enter and Space activate focused rows just like a desktop home surface.",
      props: baseline,
      play: keyboard,
    },
  },
});
