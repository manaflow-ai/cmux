// Pure model of the sidebar's per-project caps (Leo, 2026-11-10): each project shows its 5 most
// recent chats, then "Show N more", which opens inline 20 at a time and reads "Show less" once
// everything shows. Active chats always show whatever the cap: pinned, running, unread (blue) and
// waiting on you (yellow). Yellow then blue float to the top of the project, below pinned;
// running chats keep their recency place. The native Swift sidebar implements the same rules; this
// file is the gallery's copy, with tests (projectCapsModel.test.ts).

export type ChatState = "idle" | "running" | "unread" | "waiting";

export type CapChat = Readonly<{
  id: string;
  title: string;
  /** Harness id: picks the row's icon colour (a stable per-item fallback). */
  harness: string;
  /** Faint relative age shown at rest. */
  age: string;
  state: ChatState;
  pinned?: boolean;
  selected?: boolean;
}>;

export type CapProject = Readonly<{
  id: string;
  name: string;
  /** Most recent first. */
  chats: readonly CapChat[];
}>;

/** Rows a project shows before "Show N more". */
export const RECENT_CAP = 5;
/** Rows each "Show more" adds. */
export const PAGE_SIZE = 20;
/** Rows the Needs you section shows before its "N more". */
export const NEEDS_YOU_CAP = 3;

/** A row of a project and the page it opens on (0: always shown; n: the nth "Show more"). */
export type CapRow = Readonly<{ chat: CapChat; page: number }>;

export type ProjectLayout = Readonly<{
  rows: readonly CapRow[];
  /** Pages behind "Show more"; 0 when everything fits under the cap. */
  pages: number;
  /** Rows each page adds, by page index (page 1 at [0]). */
  pageCounts: readonly number[];
}>;

const floatRank = (chat: CapChat) => (chat.pinned ? 0 : chat.state === "waiting" ? 1 : chat.state === "unread" ? 2 : 3);

/** Always shown whatever the cap. */
export const isActive = (chat: CapChat) => chat.pinned === true || chat.state !== "idle";

/**
 * The project's rows in display order, each tagged with the page that reveals it. Pinned, then
 * waiting (yellow), then unread (blue) float to the top in recency order; the rest keep recency
 * order, running included. Floated and running rows are page 0; idle rows fill the 5-row cap in
 * recency order, then pages of 20.
 */
export function layoutProject(chats: readonly CapChat[]): ProjectLayout {
  const floated = chats.filter((chat) => floatRank(chat) < 3).sort((a, b) => floatRank(a) - floatRank(b));
  const rest = chats.filter((chat) => floatRank(chat) === 3);
  const rows: CapRow[] = floated.map((chat) => ({ chat, page: 0 }));
  let budget = Math.max(0, RECENT_CAP - floated.length);
  let idle = 0;
  for (const chat of rest) {
    if (chat.state === "running") {
      rows.push({ chat, page: 0 });
      budget = Math.max(0, budget - 1);
      continue;
    }
    if (budget > 0) {
      rows.push({ chat, page: 0 });
      budget -= 1;
      continue;
    }
    rows.push({ chat, page: 1 + Math.floor(idle / PAGE_SIZE) });
    idle += 1;
  }
  const pages = Math.ceil(idle / PAGE_SIZE);
  const pageCounts = Array.from({ length: pages }, (_, index) => Math.min(PAGE_SIZE, idle - index * PAGE_SIZE));
  return { rows, pages, pageCounts };
}

/** What the project's last row says with `open` pages showing, or null (no row). */
export function moreLabel(
  layout: ProjectLayout,
  open: number,
): { kind: "more"; count: number } | { kind: "less" } | null {
  if (layout.pages === 0) return null;
  if (open >= layout.pages) return { kind: "less" };
  const hidden = layout.pageCounts.slice(open).reduce((sum, count) => sum + count, 0);
  return { kind: "more", count: hidden };
}

/** Needs you: yellow rows first, then blue, across projects in project order; at most 3 shown. */
export function needsYou(projects: readonly CapProject[]): { shown: CapChat[]; more: number } {
  const all = projects.flatMap((project) => project.chats);
  const ordered = [...all.filter((chat) => chat.state === "waiting"), ...all.filter((chat) => chat.state === "unread")];
  return { shown: ordered.slice(0, NEEDS_YOU_CAP), more: Math.max(0, ordered.length - NEEDS_YOU_CAP) };
}
