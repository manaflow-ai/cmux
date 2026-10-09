// l10n-allow-file: gallery fixtures (sample sessions and folders), not shipped UI.
import { useState } from "react";
import { componentEntry } from "../../gallery/format";
import type { Play } from "../../gallery/play";
import type { AcpmuxSessionEntry } from "./sessionList";
import { SessionSidebar } from "./SessionSidebar";

type Props = {
  sessions: AcpmuxSessionEntry[];
  settledSessions?: AcpmuxSessionEntry[];
  selectedId?: string;
  openIds?: string[];
  account?: { name: string; detail?: string };
  preview?: boolean;
  groupProjects?: boolean;
};

const sessions: AcpmuxSessionEntry[] = [
  {
    sessionId: "web-1",
    displayTitle: "Fix the checkout page",
    cwd: "/Users/you/src/web",
    updatedAt: 50,
    status: "waiting",
    pendingPermissions: 1,
  },
  {
    sessionId: "app-1",
    displayTitle: "Port the sidebar",
    cwd: "/Users/you/src/app",
    updatedAt: 40,
    status: "running",
  },
  {
    sessionId: "cmux-1",
    displayTitle: "Review composer polish",
    cwd: "/Users/you/src/cmux",
    updatedAt: 35,
    status: "idle",
    unread: true,
  },
  ...Array.from({ length: 5 }, (_, index): AcpmuxSessionEntry => ({
    sessionId: `app-old-${index}`,
    displayTitle: `Older app task ${index + 1}`,
    cwd: "/Users/you/src/app",
    updatedAt: 30 - index,
    status: "idle",
  })),
];

const settledSessions: AcpmuxSessionEntry[] = [
  {
    sessionId: "settled-1",
    displayTitle: "Ship the new tab layout",
    cwd: "/Users/you/src/cmux",
    updatedAt: 12,
    status: "closed",
  },
];

const keyboard: Play = async (ctx) => {
  await ctx.focus({ selector: ".acpmux-session-row" });
  await ctx.press("ArrowDown");
  await ctx.waitFor(() => ctx.document.activeElement?.getAttribute("data-session-id") === "app-1");
};

const history: Play = async (ctx) => {
  await ctx.click({ role: "button", name: "History" });
  await ctx.waitFor(() => ctx.document.querySelector(".acpmux-sidebar-title"));
};

const search: Play = async (ctx) => {
  await ctx.click({ role: "searchbox", name: "Search sessions" });
  await ctx.type("composer");
  await ctx.waitFor(() => ctx.document.querySelector('[data-session-id="cmux-1"]'));
};

export default componentEntry<Props>({
  id: "agent-pane.session-sidebar",
  title: "Session sidebar",
  area: "Agent pane",
  height: 500,
  widths: { narrow: 280, normal: 320, wide: 380 },
  covers: ["agent-session/acpmux/SessionSidebar.tsx#SessionSidebar"],
  load: async () =>
    function GallerySessionSidebar(input: Props) {
      const [selectedId, setSelectedId] = useState(input.selectedId);
      return (
        <SessionSidebar
          {...input}
          selectedId={selectedId}
          openIds={new Set(input.openIds ?? [])}
          onSelect={setSelectedId}
        />
      );
    },
  styles: () => import("./styles.css"),
  anchors: [{ selector: ".acpmux-sidebar" }],
  checks: {
    anchorMovePx: {
      value: 0,
      reason: "Sidebar filtering and rail navigation must keep the sidebar frame fixed while only its rows change.",
    },
    layoutShiftMax: {
      value: 0,
      reason: "Changing the sidebar view must not reflow the surrounding pane or its fixed rail.",
    },
    longFrameFailMs: {
      value: 33,
      reason: "Session navigation and filtering should settle within one display frame on the gallery host.",
    },
  },
  variants: {
    sessions: {
      props: {
        sessions,
        selectedId: "app-1",
        openIds: ["app-1"],
        account: { name: "Leo", detail: "Personal" },
        groupProjects: true,
      },
    },
    keyboard: {
      props: { sessions, selectedId: "web-1", groupProjects: true },
      play: keyboard,
    },
    history: {
      props: { sessions, selectedId: "app-1", settledSessions, preview: true, groupProjects: true },
      play: history,
    },
    search: {
      props: { sessions, selectedId: "app-1", groupProjects: true },
      play: search,
    },
    "empty-settled": {
      props: { sessions: [], settledSessions, selectedId: "settled-1", account: { name: "Leo" } },
    },
  },
});
