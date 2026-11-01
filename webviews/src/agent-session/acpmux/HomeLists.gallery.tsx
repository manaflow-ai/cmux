// l10n-allow-file: gallery fixture labels and session titles, not shipped UI.
//
// HomeLists is the welcome surface between the hero and the composer. Its most important
// contract is easy to lose in the full pane: only other, listed sessions appear; every open ask of
// those chats is in the inbox (Needs you), answered in place, while review-ready pull requests keep
// a three-row cap; each row is a real button. The inbox's three looks (list, the home's; compact;
// grouped by folder) are variants here.
import { useState, type ComponentProps } from "react";
import { componentEntry } from "../../gallery/format";
import { minutesAgo } from "../../gallery/clock";
import { chat, session } from "../../gallery/fixtures/acpmux";
import type { Play } from "../../gallery/play";
import type { AcpmuxPermission } from "./model";
import type { WatchedAsk } from "./needsYou/model";
import { Composer } from "./Composer";
import { EmptyState } from "./EmptyState";
import { HomeLists } from "./HomeLists";

type Props = ComponentProps<typeof HomeLists>;

const inputSessions = [
  session({
    sessionId: "home-input-checkout",
    title: "Fix the checkout page",
    status: "waiting",
    indicator: "input",
    pendingPermissions: 1,
    updatedAt: minutesAgo(2),
    preview: "The payment form needs your answer.",
  }),
  session({
    sessionId: "home-input-cache",
    title: "Investigate the build cache",
    harness: "codex",
    cwd: "/Users/you/src/build-tools",
    indicator: "input",
    pendingPermissions: 1,
    updatedAt: minutesAgo(5),
    preview: "The runner is waiting for permission.",
  }),
  session({
    sessionId: "home-input-auth",
    title: "Settings sign-in",
    indicator: "input",
    pendingPermissions: 1,
    updatedAt: minutesAgo(9),
  }),
  // Its ask lives on the other computer: one row, which opens the chat.
  session({
    sessionId: "home-input-remote",
    title: "Release notes",
    host: "build-box",
    hostKind: "cloud",
    peer: "build-box",
    indicator: "input",
    pendingPermissions: 1,
    waitingOn: { on: "question", prompt: "Which tag should the notes start from?" },
    updatedAt: minutesAgo(31),
  }),
];

const yesNo: AcpmuxPermission["options"] = [
  { id: "allow_once", name: "Allow", kind: "allow_once", allow: true },
  { id: "allow_always", name: "Always allow", kind: "allow_always", allow: true },
  { id: "reject_once", name: "Deny", kind: "reject_once", allow: false },
];
const asks: WatchedAsk[] = [
  {
    sessionId: "home-input-checkout",
    at: minutesAgo(2),
    permission: {
      permissionId: "home-ask-checkout",
      title: "Run the payment tests",
      kind: "execute",
      command: "bun test payments",
      pending: true,
      options: yesNo,
    },
  },
  {
    sessionId: "home-input-cache",
    at: minutesAgo(5),
    permission: {
      permissionId: "home-ask-cache",
      title: "Delete the stale build cache",
      kind: "execute",
      command: "rm -rf .cache/build",
      pending: true,
      options: yesNo,
    },
  },
  {
    sessionId: "home-input-auth",
    at: minutesAgo(9),
    permission: {
      permissionId: "home-ask-auth",
      pending: true,
      options: yesNo,
      question: {
        id: "home-ask-auth",
        source: {
          harness: "claude",
          session: "home-input-auth",
          permission: "home-ask-auth",
          answerOption: "allow_once",
        },
        items: [
          {
            id: "q0",
            header: "Auth",
            prompt: "Which sign-in should the settings page use?",
            options: [
              { id: "OAuth", label: "OAuth" },
              { id: "Passkeys", label: "Passkeys" },
            ],
            multiSelect: false,
            allowsOther: true,
          },
        ],
        state: { kind: "pending" },
      },
    },
  },
  // The current chat's own ask is its card's, never the inbox's.
  {
    sessionId: "home-current",
    at: minutesAgo(0),
    permission: { permissionId: "home-ask-current", title: "Edit App.tsx", pending: true, options: yesNo },
  },
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
  asks,
  onSelect: () => undefined,
  onAnswer: () => Promise.resolve("answered" as const),
};

// Equal-length ages with narrow and wide digits expose proportional-number drift.
const numericAges = (minutes: number): Props => ({
  ...baseline,
  sessions: baseline.sessions.map((entry) => ({
    ...entry,
    activityAt: minutesAgo(minutes),
    updatedAt: minutesAgo(minutes),
  })),
  asks: asks.map((ask) => ({ ...ask, at: minutesAgo(minutes) })),
});

const empty: Props = {
  sessions: [current, ...hidden],
  currentId: current.sessionId,
  onSelect: () => undefined,
  onAnswer: () => Promise.resolve("answered" as const),
};

// The differing path endings are outside a narrow row's visible command prefix.
const longCommands: Props = {
  ...baseline,
  sessions: inputSessions.slice(0, 2),
  asks: asks.slice(0, 2).map((ask, index) => ({
    ...ask,
    permission: {
      ...ask.permission,
      title: "Run the payment tests",
      command: `bun test packages/payments/integration/checkout/subscriptions/regression/${index === 0 ? "annual-renewal.test.ts" : "monthly-renewal.test.ts"}`,
    },
  })),
};

// Long titles and folders cut at the row's edge (their whole value is the tooltip), and ages past
// a week read as a date instead of "45d ago" or "3mo ago" (#28079).
const DAY_MINUTES = 24 * 60;
const longValues: Props = {
  ...baseline,
  sessions: [
    session({
      sessionId: "home-long-input",
      title: "Reconcile the payment ledger against the processor export before the quarterly close",
      cwd: "/Users/sample/projects/atlas-web-payments-reconciliation-service",
      status: "waiting",
      indicator: "input",
      pendingPermissions: 1,
      updatedAt: minutesAgo(9 * DAY_MINUTES),
    }),
    session({
      sessionId: "home-long-review",
      title: "Retry policy",
      cwd: "/Users/sample/projects/atlas-web-payments-reconciliation-service",
      updatedAt: minutesAgo(45 * DAY_MINUTES),
      pullRequest: {
        number: 19050,
        title: "Make the reconciliation worker retry with backoff so a dropped connection never double-charges",
        state: "open",
        reviewReady: true,
      },
    }),
    session({
      sessionId: "home-recent-review",
      title: "Polish the sidebar",
      updatedAt: minutesAgo(3 * DAY_MINUTES),
      pullRequest: { number: 19051, title: "Polish the sidebar", state: "open", reviewReady: true },
    }),
    current,
  ],
  asks: [
    {
      sessionId: "home-long-input",
      at: minutesAgo(9 * DAY_MINUTES),
      permission: {
        permissionId: "home-long-ask",
        title: "Write reconciliation/processor-export/2026-q3/ledger-differences-by-merchant.csv",
        pending: true,
        options: yesNo,
      },
    },
  ],
};

const cappedInput = Array.from({ length: 5 }, (_, index) =>
  session({
    sessionId: `home-cap-input-${index + 1}`,
    title: `Waiting session ${index + 1}`,
    status: "waiting",
    indicator: "input",
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
  onAnswer: () => Promise.resolve("answered" as const),
};

/// The new chat the lists sit in: no turns yet, in the fixture project's folder.
const newChat = chat([], { title: "New chat" });
const NoChips = () => null;

/// The new chat's own frame (App.tsx): the hero in the stage, then the bottom stack with the home
/// area over the real composer, so an empty home still shows the new chat it belongs to.
function withReceipt(Component: typeof HomeLists) {
  return function GalleryHomeLists(props: Props) {
    const [selected, setSelected] = useState<string>();
    const [answered, setAnswered] = useState<string>();
    return (
      <section
        className="acpmux-shell home-lists-gallery"
        aria-label={newChat.summary?.title}
        data-home-selection={selected ?? ""}
        data-home-answer={answered ?? ""}
      >
        <div className="acpmux-main" data-new-chat="">
          <div className="acpmux-stage">
            <EmptyState project="atlas-web" />
          </div>
          <div className="acpmux-dock">
            <div className="acpmux-home-area">
              <Component
                {...props}
                onSelect={(sessionId) => {
                  props.onSelect(sessionId);
                  setSelected(sessionId);
                }}
                onAnswer={(item, choice) => {
                  setAnswered(`${item.permissionId}:${choice.id}`);
                  return props.onAnswer(item, choice);
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

const click: Play = async (ctx) => {
  await ctx.click({ role: "button", name: /Polish the sidebar/ });
  await ctx.waitFor(
    () =>
      ctx.document.querySelector(".home-lists-gallery")?.getAttribute("data-home-selection") === "home-review-sidebar",
  );
};

const selection = (ctx: Parameters<Play>[0], id: string) =>
  ctx.waitFor(() => ctx.document.querySelector(".home-lists-gallery")?.getAttribute("data-home-answer") === id);

const answer: Play = async (ctx) => {
  await ctx.click({ role: "button", name: /^Allow once/ });
  await selection(ctx, "home-ask-checkout:allow_once");
};

const shortcut: Play = async (ctx) => {
  const view = ctx.document.defaultView!;
  view.dispatchEvent(new view.Event("cmux-acpmux-permissionDeny"));
  await selection(ctx, "home-ask-checkout:reject_once");
};

const refusedAnswer: Play = async (ctx) => {
  await ctx.click({ role: "button", name: /^Allow once/ });
  await ctx.waitFor(() => Boolean(ctx.document.querySelector(".acpmux-home-inbox-error")));
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
  pane: true,
  height: 640,
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
    "long-commands": {
      note: "Long commands share a prefix but have different file names; each full command remains inspectable on hover.",
      props: longCommands,
    },
    baseline: {
      note: "Needs you lists every other chat's ask with its chat, folder and age, Allow once and Deny in place (the first takes ⌥⌘1 and ⌥⌘3); a question and another computer's chat open their chat. Ready for review stays separate, and the current, archived, side and not-ready chats stay out.",
      props: baseline,
    },
    "ages-11": {
      note: "Inbox and review ages with narrow digits: 11 minutes. Compare ages-58 at the same width and theme.",
      props: numericAges(11),
    },
    "ages-58": {
      note: "The same inbox and review ages with wide digits: 58 minutes. The numeric text keeps the width of ages-11.",
      props: numericAges(58),
    },
    compact: {
      note: "The compact look: one line per ask, its answers at its end.",
      props: { ...baseline, look: "compact" },
    },
    grouped: {
      note: "Grouped by the chat's folder: the folder once, then its asks.",
      props: { ...baseline, look: "grouped" },
    },
    answer: {
      note: "Allow once sends that ask's own option, and the row leaves.",
      props: baseline,
      play: answer,
    },
    "deny-shortcut": {
      note: "⌥⌘3 denies the first ask the inbox can answer.",
      props: baseline,
      play: shortcut,
    },
    refused: {
      note: "A refused answer says so on its row, and the row answers again.",
      props: { ...baseline, onAnswer: () => Promise.reject(new Error("no pending permission")) },
      play: refusedAnswer,
    },
    empty: {
      note: "A clean new chat has no home lists when every other session is current, archived, side, or not ready.",
      props: empty,
    },
    "long-values": {
      note: "Long titles, asks and folders cut at the row's edge and carry their whole value as a tooltip; ages from a week on read as a date.",
      props: longValues,
    },
    "cap-filter": {
      note: "Ready for review caps at three newest rows; chats with no ask read here still show in Needs you, so none is left to find.",
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
