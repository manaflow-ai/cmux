// Pure model of the sidebar's per-project caps (Leo, 2026-11-10): each project shows its first 5
// quiet chats, then "Show N more", which opens inline 20 at a time and reads "Show less" once
// everything shows. Active chats always show and never use up the cap: pinned, the selected row,
// running, unread (blue) and waiting on you (yellow). Pinned come first, then yellow, then blue
// float to the top of the project; running and selected chats keep their place. One row over the
// cap shows whole (a row that hides one row saves nothing). This is the gallery's copy of the Rust
// rule (`cmux-layout-reducer::sidebar_caps`), with tests (projectCapsModel.test.ts).

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

/** 0 pinned, 1 waiting (yellow), 2 unread (blue): the rows that float, in that order. */
const floatRank = (chat: CapChat) => (chat.pinned ? 0 : chat.state === "waiting" ? 1 : chat.state === "unread" ? 2 : 3);

/** Always shown whatever the cap, and never counted against it. */
export const isActive = (chat: CapChat) => chat.pinned === true || chat.selected === true || chat.state !== "idle";

/**
 * The project's rows in display order, each tagged with the page that reveals it. Pinned, then
 * waiting (yellow), then unread (blue) float to the top in recency order; the rest keep recency
 * order. Active rows are page 0 and leave the cap alone; quiet rows fill the 5-row cap, then pages
 * of 20, and a last page of one row joins the page before it.
 */
export function layoutProject(chats: readonly CapChat[]): ProjectLayout {
  const floated = chats.filter((chat) => floatRank(chat) < 3).sort((a, b) => floatRank(a) - floatRank(b));
  const quietTotal = chats.filter((chat) => !isActive(chat)).length;
  const pageCounts: number[] = [];
  for (let left = quietTotal - RECENT_CAP; left > 0; left -= PAGE_SIZE) pageCounts.push(Math.min(PAGE_SIZE, left));
  // One row over a limit shows whole: fold a last page of one into the page before it (or the cap).
  if (pageCounts.length > 0 && pageCounts[pageCounts.length - 1] === 1) {
    pageCounts.pop();
    if (pageCounts.length > 0) pageCounts[pageCounts.length - 1]! += 1;
  }
  const pageOf = (quietIndex: number) => {
    let end = quietTotal - pageCounts.reduce((sum, count) => sum + count, 0);
    if (quietIndex < end) return 0;
    for (let page = 0; page < pageCounts.length; page += 1) {
      end += pageCounts[page]!;
      if (quietIndex < end) return page + 1;
    }
    return pageCounts.length;
  };
  const rows: CapRow[] = floated.map((chat) => ({ chat, page: 0 }));
  let quiet = 0;
  for (const chat of chats) {
    if (floatRank(chat) < 3) continue;
    if (isActive(chat)) rows.push({ chat, page: 0 });
    else rows.push({ chat, page: pageOf(quiet++) });
  }
  return { rows, pages: pageCounts.length, pageCounts };
}

/**
 * What the project's last row says with `open` pages showing, or null (no row). The count is how
 * many one press reveals: 20 while 20 or more hide, else the rest.
 */
export function moreLabel(
  layout: ProjectLayout,
  open: number,
): { kind: "more"; count: number } | { kind: "less" } | null {
  if (layout.pages === 0) return null;
  if (open >= layout.pages) return { kind: "less" };
  const hidden = layout.pageCounts.slice(open).reduce((sum, count) => sum + count, 0);
  return { kind: "more", count: Math.min(PAGE_SIZE, hidden) };
}

/** Needs you: yellow rows first, then blue, across projects in project order; at most 3 shown. */
export function needsYou(projects: readonly CapProject[]): { shown: CapChat[]; rest: CapChat[]; more: number } {
  const all = projects.flatMap((project) => project.chats);
  const ordered = [...all.filter((chat) => chat.state === "waiting"), ...all.filter((chat) => chat.state === "unread")];
  const rest = ordered.slice(NEEDS_YOU_CAP);
  return { shown: ordered.slice(0, NEEDS_YOU_CAP), rest, more: rest.length };
}
