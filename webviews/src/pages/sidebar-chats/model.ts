// The sidebar's chat history blocks (cmux-page://cmux.sidebar-chats/): what one block draws and the
// ops it sends its native host (SidebarChatHistoryPage.swift, CmuxNextSidebar). The sidebar lists two
// blocks when the session tree is on, Pinned above the workspaces and Earlier under them; each is its
// own page in the list's gap for it. The host owns the data, the heights and every action: it streams
// one block per change, and a click goes back as a call the host checks against the person's own
// gesture and the rows it sent. The page only draws and reports.

export const SidebarChatsOps = {
  /** Stream: the block to draw, with a new `revision` on every change. */
  block: "cmux.sidebarChats.block",
  /** {revision, chat}: a row was clicked; the host opens (resumes) the chat. */
  open: "cmux.sidebarChats.open",
  /** {revision}: Earlier's header was clicked; the host folds or unfolds Earlier. */
  fold: "cmux.sidebarChats.fold",
  /** {revision}: Show More was clicked; the host lists the next page. */
  more: "cmux.sidebarChats.more",
  /** {revision, chat, point: {x, y}}: a row's right click; the host shows its Pin or Unpin menu at `point`. */
  menu: "cmux.sidebarChats.menu",
  /** {revision, height}: `revision` is drawn and is `height` CSS px tall (the host's gap for it). */
  ready: "cmux.sidebarChats.ready",
} as const;

export type SidebarChatsPart = "pinned" | "earlier";

/** One chat row. `meta` is its age ("12m"), formatted by the host; `markColor` is set for a harness no
 * mark knows, whose generic mark takes that stable colour. */
export interface SidebarChatRow {
  id: string;
  title: string;
  meta?: string | null;
  harness?: string | null;
  markColor?: string | null;
}

/** The sidebar's grid in CSS px (one px is one point: the page keeps the sidebar's scale). */
export interface SidebarChatsMetrics {
  /** The header's height, a row's height and the gap under each row. */
  header: number;
  row: number;
  spacing: number;
  /** A row's hover fill corner. */
  radius: number;
  /** The icon column's leading edge and box, and the mark's side in it. */
  iconX: number;
  iconBox: number;
  glyph: number;
  /** Where a row's title starts with a mark, and without one (Show More, Loading). */
  textX: number;
  plainTextX: number;
  /** Where the header's name starts. */
  headerX: number;
  /** A row's age ends this far from the right edge. */
  edge: number;
  /** The header's name ends this far from the right edge (clear of the chevron's column). */
  headerEnd: number;
  /** The chevron's right edge from the block's right edge, and its side. */
  chevronEnd: number;
  chevron: number;
  /** The title, age and header point sizes. */
  titleSize: number;
  metaSize: number;
  headerSize: number;
}

export interface SidebarChatsBlock {
  revision: number;
  part: SidebarChatsPart;
  /** Earlier is folded to its header (no rows, no Show More). */
  folded: boolean;
  rows: SidebarChatRow[];
  /** The row under the page: Show More, Loading (acpmux has not sent Earlier's rows yet), or none. */
  tail: "more" | "loading" | null;
  metrics: SidebarChatsMetrics;
}

export interface SidebarChatsStrings {
  pinned: string;
  earlier: string;
  showMore: string;
  loading: string;
}

/** The block drawn before the host's first event: nothing (height 0). */
export const NO_BLOCK: SidebarChatsBlock | null = null;

/** Earlier folds; Pinned does not. */
export function isFoldable(block: SidebarChatsBlock): boolean {
  return block.part === "earlier";
}

/** The block's height in CSS px, as the host's layout reserves it (`SidebarChatHistoryState.pinnedHeight` and
 * `earlierHeight`): the header, then a row and its spacing for each chat and the tail. */
export function blockHeight(block: SidebarChatsBlock): number {
  const { header, row, spacing } = block.metrics;
  if (block.folded) return header;
  const rows = block.rows.length + (block.tail ? 1 : 0);
  return header + rows * (row + spacing);
}

/** A row's spoken name: its title, its harness and its age, as the AppKit row read. */
export function rowLabel(row: SidebarChatRow): string {
  return [row.title, row.harness, row.meta].filter((part): part is string => !!part).join(", ");
}

/** A block event from the host, checked: anything that is not one is dropped. */
export function parseBlock(data: unknown): SidebarChatsBlock | null {
  if (!data || typeof data !== "object") return null;
  const value = data as Partial<SidebarChatsBlock>;
  if (typeof value.revision !== "number" || (value.part !== "pinned" && value.part !== "earlier")) return null;
  if (!Array.isArray(value.rows) || !value.metrics || typeof value.metrics !== "object") return null;
  const rows = value.rows.filter(
    (row): row is SidebarChatRow =>
      !!row && typeof row === "object" && typeof row.id === "string" && typeof row.title === "string",
  );
  const tail = value.tail === "more" || value.tail === "loading" ? value.tail : null;
  return { revision: value.revision, part: value.part, folded: !!value.folded, rows, tail, metrics: value.metrics };
}
