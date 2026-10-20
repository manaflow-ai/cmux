// l10n-allow-file: gallery fixtures (sample sessions), not shipped UI.
// The sidebar's list, rail and session actions are rendered by the real SessionSidebar component;
// callbacks are no-ops because this gallery lane measures the interaction surface, not the host.
import type { ComponentProps } from "react";
import { componentEntry } from "../../gallery/format";
import { minutesAgo } from "../../gallery/clock";
import { session } from "../../gallery/fixtures/acpmux";
import type { PlayContext } from "../../gallery/play";
import type { SessionSidebar } from "./SessionSidebar";

type Props = ComponentProps<typeof SessionSidebar>;

const sessions: Props["sessions"] = [
  session({
    sessionId: "sidebar-first",
    title: "Fix the checkout page",
    updatedAt: minutesAgo(1),
    status: "running",
    indicator: "working",
    preview: "The checkout still needs a final pass on the payment form.",
    cwd: "/Users/you/src/cmux",
    branch: "feat/checkout",
  }),
  session({
    sessionId: "sidebar-second",
    title: "Port the sidebar",
    updatedAt: minutesAgo(2),
    unread: true,
    indicator: "done",
    cwd: "/Users/you/src/cmux",
    branch: "feat/sidebar-polish",
  }),
  session({
    sessionId: "sidebar-third",
    title: "Profile transcript scrolling",
    updatedAt: minutesAgo(3),
    cwd: "/Users/you/src/cmux",
    status: "idle",
  }),
  session({
    sessionId: "sidebar-cloud",
    title: "Review the cloud build",
    updatedAt: minutesAgo(4),
    cwd: "/workspace/cmux",
    host: "Build runner",
    hostKind: "cloud",
    peer: "Build runner",
    branch: "ci/nightly",
  }),
];

/** An agent whose sub-session waits for the person to trust a folder (hub/trust_wait.rs). */
const trustWaiting: Props["sessions"] = [
  session({
    sessionId: "sidebar-trust",
    title: "Split the importer into parts",
    updatedAt: minutesAgo(1),
    status: "waiting",
    indicator: "input",
    trustPending: "/Users/you/src/vendor-sdk",
    cwd: "/Users/you/src/cmux",
    branch: "feat/importer",
  }),
  ...sessions.slice(0, 2),
];

const sessionsWithoutPreview = sessions.map((entry) => ({ ...entry, preview: undefined }));

const active = session({
  sessionId: "sidebar-active",
  title: "Fix the active bug",
  updatedAt: minutesAgo(1),
  status: "running",
  indicator: "working",
});
const settled = session({
  sessionId: "sidebar-settled",
  title: "Review the settled draft",
  updatedAt: minutesAgo(2),
  status: "closed",
});

const baseProps: Props = {
  sessions,
  selectedId: "sidebar-first",
  onSelect: () => undefined,
  onNewChat: () => undefined,
  account: { name: "Leo", detail: "Personal" },
  groupProjects: true,
  preview: true,
  openIds: new Set(["sidebar-second"]),
};

const waitForActiveRow = (ctx: PlayContext, id: string) =>
  ctx.waitFor(() => ctx.document.activeElement?.getAttribute("data-session-id") === id);

const search = async (ctx: PlayContext) => {
  await ctx.type("sidebar", { selector: 'input[aria-label="Search sessions"]' });
  await ctx.waitFor(() => ctx.document.querySelectorAll(".acpmux-session-row").length === 2);
};

const searchThenClear = async (ctx: PlayContext) => {
  await search(ctx);
  await ctx.press("Escape");
  await ctx.waitFor(
    () => ctx.document.querySelector<HTMLInputElement>('input[aria-label="Search sessions"]')?.value === "",
  );
};

const rowKeyboard = async (ctx: PlayContext) => {
  await ctx.focus({ selector: ".acpmux-session-row" });
  await ctx.press("ArrowDown");
  await waitForActiveRow(ctx, "sidebar-second");
  await ctx.press("End");
  await waitForActiveRow(ctx, "sidebar-cloud");
  await ctx.press("Home");
  await waitForActiveRow(ctx, "sidebar-first");
};

const railKeyboard = async (ctx: PlayContext) => {
  await ctx.focus({ role: "button", name: /Sessions/ });
  await ctx.press("ArrowDown");
  await ctx.waitFor(() => ctx.document.activeElement?.getAttribute("aria-label") === "History");
  await ctx.press("End");
  await ctx.waitFor(() => ctx.document.activeElement?.getAttribute("aria-label") === "Closed sessions");
  await ctx.press("Home");
  await ctx.waitFor(() => ctx.document.activeElement?.getAttribute("aria-label") === "Sessions");
};

const switchViews = async (ctx: PlayContext) => {
  await ctx.click({ role: "button", name: "History" });
  await ctx.waitFor(() => ctx.document.querySelector('[aria-label="History"] .acpmux-sidebar-title'));
  await ctx.click({ role: "button", name: "Pull requests" });
  await ctx.waitFor(() => ctx.document.querySelector('[aria-label="Pull requests"] .acpmux-sidebar-empty'));
  await ctx.click({ role: "button", name: "Closed sessions" });
  await ctx.waitFor(() => ctx.document.querySelector('[aria-label="Closed sessions"] .acpmux-sidebar-title'));
};

/**
 * The sidebar's rail is also the workspace-switch affordance in the native shell. Keep one
 * canonical rapid round-trip for visual review: the play runner records each transition's frame
 * timing, settle latency, anchor geometry and layout shift. This deliberately uses the existing
 * play/manifest contract instead of introducing a second animation recorder.
 */
const animationAudit = async (ctx: PlayContext) => {
  const sidebar = ctx.find({ selector: ".acpmux-sidebar" });
  const before = sidebar.getBoundingClientRect();
  const transitions: Array<[string, string]> = [
    ["History", 'section[aria-label="History"] .acpmux-sidebar-title'],
    ["Pull requests", 'section[aria-label="Pull requests"] .acpmux-sidebar-empty'],
    ["Closed sessions", 'section[aria-label="Closed sessions"] .acpmux-sidebar-title'],
    ["Sessions", ".acpmux-sidebar-active"],
  ];
  for (const [label, section] of transitions) {
    await ctx.click({ role: "button", name: label });
    await ctx.waitFor(() => ctx.document.querySelector(section) !== null);
    const after = sidebar.getBoundingClientRect();
    const moved = Math.max(
      Math.abs(before.left - after.left),
      Math.abs(before.top - after.top),
      Math.abs(before.width - after.width),
      Math.abs(before.height - after.height),
    );
    if (moved > 0.5) throw new Error(`${label} moved the sidebar frame by ${moved.toFixed(1)}px`);
  }
};

const contextActions = async (ctx: PlayContext) => {
  const openMenu = (sessionId: string) => {
    const row = ctx.find({ selector: `[data-session-id="${sessionId}"]` });
    const box = row.getBoundingClientRect();
    const view = ctx.document.defaultView!;
    row.dispatchEvent(
      new view.MouseEvent("contextmenu", {
        bubbles: true,
        cancelable: true,
        clientX: box.left + 24,
        clientY: box.top + 12,
      }),
    );
  };

  openMenu("sidebar-active");
  await ctx.waitFor(() => ctx.document.querySelector('[role="menu"] [role="menuitem"]'));
  await ctx.click({ role: "menuitem", name: "Settle" });
  await ctx.waitFor(() => !ctx.document.querySelector('[role="menu"]'));

  openMenu("sidebar-settled");
  await ctx.waitFor(() => ctx.document.querySelector('[role="menu"] [role="menuitem"]'));
  await ctx.click({ role: "menuitem", name: "Continue" });
  await ctx.waitFor(() => !ctx.document.querySelector('[role="menu"]'));
};

const hoverPreview = async (ctx: PlayContext) => {
  await ctx.hover({ selector: '[data-session-id="sidebar-first"]' });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-session-preview"));
};

const focusPreview = async (ctx: PlayContext) => {
  await ctx.focus({ selector: '[data-session-id="sidebar-first"]' });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-session-preview"));
};

const entry = componentEntry<Props>({
  id: "agent-pane.session-sidebar",
  title: "Session sidebar",
  area: "Agent pane",
  pane: true,
  height: 620,
  widths: { narrow: 300, normal: 380, wide: 520 },
  anchors: [{ selector: ".acpmux-sidebar" }, { selector: ".acpmux-rail" }],
  checks: {
    anchorMovePx: {
      value: 0,
      reason: "Sidebar searches, menus and rail navigation must leave the sidebar frame and rail geometry stable.",
    },
    layoutShiftMax: {
      value: 0,
      reason: "Filtering and switching sidebar views replace rows inside the scroll region without moving the shell.",
    },
    longFrameFailMs: {
      value: 33,
      reason: "Sidebar filtering, menus and keyboard navigation should stay responsive on the gallery host.",
    },
    settleMaxMs: {
      value: 250,
      reason:
        "Search, rail and context-menu actions are direct local interactions with a quarter-second response budget.",
    },
  },
  covers: ["agent-session/acpmux/SessionSidebar.tsx#SessionSidebar"],
  styles: () => import("./styles.css"),
  load: () => import("./SessionSidebar").then((module) => module.SessionSidebar),
  variants: {
    baseline: {
      note: "Grouped projects, an open tab, local and cloud placement, status marks, and the account footer.",
      props: baseProps,
    },
    "trust-pending": {
      note: "An agent's sub-session waits for a folder's trust: its row says Needs trust, in the amber of the question card, instead of Needs your input.",
      props: { ...baseProps, sessions: trustWaiting, selectedId: "sidebar-first", groupProjects: false },
    },
    "search-filtered": {
      note: "Search narrows rows by title, branch, project or host while preserving project context.",
      props: { ...baseProps, groupProjects: false },
      play: search,
    },
    "search-clears": {
      note: "Escape clears the sidebar query before it can dismiss the surrounding surface.",
      props: { ...baseProps, groupProjects: false },
      play: searchThenClear,
    },
    "row-keyboard": {
      note: "ArrowDown, End and Home move through visible session rows without leaving the list.",
      props: { ...baseProps, groupProjects: false },
      play: rowKeyboard,
    },
    "rail-keyboard": {
      note: "The rail skips disabled controls and follows ArrowDown, End and Home through its views.",
      props: baseProps,
      play: railKeyboard,
    },
    "view-switching": {
      note: "History, Pull requests and Closed sessions each replace the list in the same pane.",
      props: baseProps,
      play: switchViews,
    },
    "view-switching-animation-audit": {
      note: "Rapidly round-trip the sidebar rail through History, Pull requests, Closed sessions and Sessions. The shared play report is the animation receipt: frame timing, settle latency, layout shift and sidebar geometry are checked together.",
      props: baseProps,
      checks: {
        layoutShiftMax: {
          value: 0,
          reason: "Workspace/sidebar view switches replace the scroll content without moving the sidebar frame.",
        },
        longFrameFailMs: {
          value: 33,
          reason: "Rail view switches should not introduce a long animation frame over two display frames.",
        },
        settleMaxMs: {
          value: 250,
          reason: "Each local rail transition should settle within a quarter second for rapid workspace review.",
        },
      },
      play: animationAudit,
    },
    "context-actions": {
      note: "Right-click an active row to Settle and a settled row to Continue; each menu returns focus cleanly.",
      props: {
        ...baseProps,
        sessions: [active],
        settledSessions: [settled],
        groupProjects: false,
        onSettle: () => undefined,
        onContinue: () => undefined,
      },
      play: contextActions,
    },
    "hover-preview": {
      note: "A deliberate hover opens the latest reply with status and placement metadata in a floating card.",
      props: { ...baseProps, groupProjects: false },
      play: hoverPreview,
    },
    "hover-preview-quiet": {
      note: "Debug layout sidebarPreviewVariant=quiet: a narrower, flatter latest-reply card keeps metadata readable with less elevation.",
      props: { ...baseProps, groupProjects: false, previewVariant: "quiet" },
      play: hoverPreview,
    },
    "hover-preview-outline": {
      note: "Debug layout sidebarPreviewVariant=outline: a lightly tinted rim keeps the latest-reply card distinct without a drop shadow.",
      props: { ...baseProps, groupProjects: false, previewVariant: "outline" },
      play: hoverPreview,
    },
    "focus-preview": {
      note: "Keyboard focus opens the same preview without changing the sidebar row geometry.",
      props: { ...baseProps, groupProjects: false },
      play: focusPreview,
    },
    "no-preview": {
      note: "Rows without a latest reply remain compact and do not mount a preview card.",
      props: { ...baseProps, sessions: sessionsWithoutPreview, groupProjects: false },
    },
  },
});

export default entry;
