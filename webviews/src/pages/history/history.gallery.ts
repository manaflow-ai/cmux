// l10n-allow-file: gallery fixtures (sample history), not shipped UI.
import { minutesAgo } from "../../gallery/clock";
import { historyPageEntry } from "../../gallery/format";
import type { HistoryEntry } from "./types";

const ago = (hours: number) => minutesAgo(hours * 60);

const entries: HistoryEntry[] = [
  {
    id: "page:local:1",
    kind: "page",
    at_ms: ago(0.2),
    title: "Atlas release notes",
    detail: "https://docs.example.test/releases",
    url: "https://docs.example.test/releases",
    profile: "default",
    available: true,
  },
  {
    id: "location:local:1",
    kind: "location",
    at_ms: ago(0.4),
    title: "webviews",
    detail: "/Users/you/src/atlas-web/webviews",
    cwd: "/Users/you/src/atlas-web/webviews",
    workspace: "atlas-web",
    current: true,
    available: true,
  },
  {
    id: "agent:local:1",
    kind: "agent",
    at_ms: ago(0.8),
    title: "Code review session",
    detail: "~/src/atlas-web",
    cwd: "/Users/you/src/atlas-web",
    workspace: "atlas-web",
    provider: "codex",
    session_id: "gallery-session-1",
    running: true,
    available: true,
  },
  {
    id: "command:local:1",
    kind: "command",
    at_ms: ago(1.2),
    title: "bun test test/gallery-coverage.test.ts",
    detail: "/Users/you/src/atlas-web/webviews",
    cwd: "/Users/you/src/atlas-web/webviews",
    command: "bun test test/gallery-coverage.test.ts",
    exit_code: 0,
    available: true,
  },
  {
    id: "closed:local:1",
    kind: "closed",
    at_ms: ago(2),
    title: "Design review — editor states",
    detail: "https://design.example.test/review/editor",
    url: "https://design.example.test/review/editor",
    closed_kind: "browser_tab",
    available: false,
  },
  {
    id: "page:local:2",
    kind: "page",
    at_ms: ago(26),
    title: "TypeScript handbook",
    detail: "https://www.typescriptlang.org/docs/",
    url: "https://www.typescriptlang.org/docs/",
    profile: "default",
    available: true,
  },
];

const many = Array.from({ length: 48 }, (_, index): HistoryEntry => ({
  id: `command:build:${index + 1}`,
  kind: "command",
  at_ms: ago(index + 3),
  title: `build step ${index + 1}: ${"long-running-gallery-task-".repeat(2)}module-${index + 1}`,
  detail: `/Users/you/src/atlas-web/packages/feature-${String(index % 8).padStart(2, "0")}`,
  cwd: `/Users/you/src/atlas-web/packages/feature-${String(index % 8).padStart(2, "0")}`,
  command: `bun run build --filter feature-${index + 1}`,
  exit_code: index % 9 === 0 ? 1 : 0,
  machine: index % 4 === 0 ? "build-mini" : undefined,
  available: index % 4 !== 0,
}));

export default historyPageEntry({
  id: "pages.history",
  title: "History",
  area: "Pages",
  height: 640,
  widths: { narrow: 560, normal: 1000, wide: 1400 },
  covers: ["page:cmux.history", "pages/history/HistoryPage.tsx#HistoryPage", "pages/history/KindIcon.tsx#KindIcon"],
  variants: {
    empty: { note: "No history entries have been recorded.", entries: [] },
    loading: { note: "The history owner is still loading the timeline.", loading: true, entries },
    normal: { note: "All five history kinds, including a running agent and an unavailable row.", entries },
    "many-entries": {
      note: "A long command timeline that scrolls and wraps long names.",
      entries: [...many, ...entries],
    },
    "filtered-selected": {
      note: "The Pages filter is selected and a row is focused.",
      entries,
      query: { filter: "pages", selectIndex: 0 },
    },
    "context-menu": {
      note: "A selected row's restore and remove actions are open.",
      entries,
      query: { menuIndex: 1 },
    },
    "network-error": { note: "The history owner is disconnected.", entries, error: "network" },
    "permission-error": {
      note: "A refused remove leaves the timeline intact; this page has no visible error notice yet.",
      entries,
      error: "permission",
      query: { menuIndex: 1 },
      play: async (ctx) => {
        await ctx.waitFor(() => ctx.document.querySelector(".page-menu-item.destructive"));
        await ctx.click({ selector: ".page-menu-item.destructive" });
        await ctx.waitFor(() => !ctx.document.querySelector(".page-menu"));
      },
    },
    "not-found-error": { note: "The history owner reports a missing source.", entries, error: "not-found" },
  },
});
