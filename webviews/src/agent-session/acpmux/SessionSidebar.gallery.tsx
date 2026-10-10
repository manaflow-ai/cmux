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
  }),
  session({
    sessionId: "sidebar-second",
    title: "Port the sidebar",
    updatedAt: minutesAgo(2),
    unread: true,
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

const active = session({
  sessionId: "sidebar-active",
  title: "Fix the active bug",
  updatedAt: minutesAgo(1),
  status: "running",
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
  },
});

export default entry;
