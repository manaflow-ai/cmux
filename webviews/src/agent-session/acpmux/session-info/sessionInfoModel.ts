import { type ChatColumn } from "../chatWidth";
import { type AcpmuxRow, transcriptColumn } from "../model";
import { tryChipHost } from "../chips/host";

export type SessionInfoPlacement = "push" | "overlay";

/// The narrowest chat Session Info pushes aside: a pushed panel narrows to keep it, down to the
/// panel's own narrowest width.
export const PUSH_MIN_CHAT = 440;
/// The room the panel keeps from the pane's right edge, floating or pushing, and from the
/// transcript's column when it floats (sessionInfo.css --acpmux-session-info-inset).
export const FLOAT_MARGIN = 8;
/// Whether Settings Push always is on: Session Info then always takes a column.
export const pushes = (placement: SessionInfoPlacement) => placement === "push";

/// The narrowest a pushed panel gets in a tight pane, below the drag's narrowest
/// (SESSION_INFO_WIDTH.min), and still as wide as the live preview card under it (computerUsePreview.css,
/// 180px). Pushed at 260px in a 370px agent pane, the chat kept about 100px, with its "Not sent" line,
/// Retry and composer under the panel (cmuxterm-hq#6137; Leo, 2026-11-02: "THE FUCKING SESSION INFO NOT
/// FUCKING PUSH THE LAYOUT LEFT").
export const PUSH_PANEL_MIN = 200;

/// A pushed panel's width: its own, narrowed so the chat keeps PUSH_MIN_CHAT beside it and its
/// right margin, down to PUSH_PANEL_MIN, and never past the pane less its margins. The chat takes the
/// rest of the pane beside it: the two never overlap.
export const pushedWidth = (paneWidth: number, width: number) =>
  paneWidth <= 0
    ? width
    : Math.max(
        0,
        Math.min(
          width,
          Math.max(PUSH_PANEL_MIN, paneWidth - PUSH_MIN_CHAT - FLOAT_MARGIN),
          paneWidth - 2 * FLOAT_MARGIN,
        ),
      );

/// Whether the pane holds a readable chat (PUSH_MIN_CHAT) beside the panel at its narrowest: the
/// boundary between pushing and lying over the chat (sessionInfoStage). Below it, Session Info does not
/// open from a saved open state alone (a new chat, a relaunch, a pane narrowed under it): over a narrow
/// chat it waits for the person's toggle. Unmeasured (0) counts as room.
export const sessionInfoFits = (paneWidth: number) =>
  paneWidth <= 0 || paneWidth - PUSH_PANEL_MIN - FLOAT_MARGIN >= PUSH_MIN_CHAT;

/// A handoff review's form (handoff/styles.css: 760px, 18px from each edge) takes the transcript's
/// place and is wider than the column.
export const HANDOFF_FORM_WIDTH = 760;
/// The form's clearance from each pane edge (handoff/styles.css `min(760px, calc(100% - 36px))`).
export const HANDOFF_FORM_EDGE = 18;
/// The floating panel's right gutter: the transcript's (model.ts transcriptColumn), or with `wide` the
/// handoff review form's.
const gutterOf = (paneWidth: number, column?: ChatColumn, wide = false) => {
  const columnInset = transcriptColumn(paneWidth, column).inset;
  return wide
    ? Math.min(columnInset, (paneWidth - Math.min(HANDOFF_FORM_WIDTH, paneWidth - 2 * HANDOFF_FORM_EDGE)) / 2)
    : columnInset;
};

/// Whether the floating panel would lie over the chat's column: the right gutter cannot hold it and
/// its margins. By default it then pushes the chat (sessionInfoPushes); where it still floats (a short
/// pane's popover, a handoff review's form), the card, full length otherwise, stops above the
/// composer's stack so it never covers the composer.
export const sessionInfoOverChat = (paneWidth: number, width: number, column?: ChatColumn, wide = false) => {
  if (paneWidth <= 0 || width <= 0) return false;
  return width + 2 * FLOAT_MARGIN > gutterOf(paneWidth, column, wide);
};

/// Below this pane height, a panel that lies over the chat is a popover: it hides when a click lands
/// anywhere else, and while it shows it covers the composer instead of stopping above it. A taller pane
/// keeps the card above the composer, its foot following the composer's top with an animation
/// (sessionInfo.css), never a jump (Leo, 2026-10-31: "THE FACT THIS SHIT FUCKING EXPANDS WHEN THE
/// COMPOSER GROWS OR SHRINKS IS... ok i guess but i feel like should have an animation... sometimes
/// the claude code/chatgpt desktop just straight up make it a popover that hides when you click away
/// when the viewport is indeed too small"). It reads the pane's height alone, never the composer's, so
/// typing a long draft never switches the panel between the two.
export const POPOVER_BELOW_HEIGHT = 520;

/// Whether the floating panel is a popover (POPOVER_BELOW_HEIGHT): it lies over the chat in a short
/// pane. A popover shows only when the person opens it (SessionInfoPresence `asked`), never from a
/// saved open state alone.
export const sessionInfoPopover = (paneHeight: number, overChat: boolean) =>
  overChat && paneHeight > 0 && paneHeight < POPOVER_BELOW_HEIGHT;

/// Where Session Info goes, by the pane's width (Leo, 2026-11-03: "but you should still be able to have
/// it be an overlay... we previously had all that behaviour logic going from not affecting layout at
/// all -> gradually pushing into the chat layout -> overlay"):
/// - `float`: the right gutter holds it and its margins; the chat does not move (Leo, 2026-10-31: "why
///   is the session info thing still pushing my layout when it doesnt need to???").
/// - `push`: the gutter cannot hold it, and pushing keeps the transcript's column at the width it has
///   without the panel (pushKeepsColumn): it pushes into the chat by only what the gutter lacks
///   (pushedRoom), so the column moves left and its text never wraps anew (Leo, 2026-11-03: "the agent
///   chat's horizontal width shouldn't be shifted its position sure but it itself and its text
///   shouldn't be affected by the session info if it would need to be then session info should be an
///   overlay").
/// - `overlay`: pushing would narrow the column: it lies over the chat and stops above the composer (a
///   popover in a short pane, POPOVER_BELOW_HEIGHT). A short pane and a handoff review's wider form never
///   push either.
/// With Settings Push always, `push` wherever its whole room keeps the column's width, else `overlay`
/// too. `overflow` is how far the chat's drawn content reaches past the column the model expects
/// (chatContentOverflow): a panel that would lie over any row or the composer does not float, whatever
/// the gutter's width says.
export type SessionInfoStage = "float" | "push" | "overlay";
export const sessionInfoStage = (
  placement: SessionInfoPlacement,
  pane: { width: number; height: number },
  width: number,
  column?: ChatColumn,
  wide = false,
  overflow = 0,
): SessionInfoStage => {
  if (!pushes(placement)) {
    // Where the gutter holds the panel, the chat does not move: it pushes only once there is no room
    // left (Leo, 2026-11-09: "if it has enough space, then don't push the layout. Don't make it affect
    // the layout. You only push when you don't have any space left").
    if (!sessionInfoOverChat(pane.width, width + (wide ? 0 : Math.max(0, overflow)), column, wide)) return "float";
    if (wide || sessionInfoPopover(pane.height, true) || !sessionInfoFits(pane.width)) return "overlay";
  }
  const room = pushedRoom(pane.width, pushedWidth(pane.width, width), column, overflow, pushes(placement));
  return pushKeepsColumn(pane.width, room, column) ? "push" : "overlay";
};

/// The shell's room Find in Chat's bar keeps from the chat's right edge (conversation.css .acpmux-find__bar).
export const SESSION_INFO_CLEAR = "--acpmux-session-info-clear";

/// How far the panel's left edge lies inside the chat's right edge, in every stage: the panel and its
/// margin, less the room a push takes from the chat beside it (`room`, pushedRoom; 0 floating or over the
/// chat). Find in Chat's bar keeps this clear, so it sits in the chat's column left of the panel and
/// never under it (Leo, 2026-11-03: "oh no the command f overlaps with the session info..").
export const sessionInfoClear = (panelWidth: number, room: number) =>
  Math.max(0, Math.round(panelWidth + FLOAT_MARGIN - room));

/// Find in Chat's bar at its narrowest (ui/findPill.css: its padding, icon, a 40px field, the count,
/// the separator and three buttons), and its inset from the column's edges (--find-pill-inset).
export const FIND_BAR_MIN = 230;
export const FIND_BAR_INSET = 10;

/// Whether a chat `chatWidth` wide has no room for Find in Chat's bar at its narrowest beside the panel
/// (`clear`, sessionInfoClear): Session Info then steps aside when Find opens (FIND_OPEN_EVENT), as it
/// does for a diff in place, instead of covering the bar; its toggle brings it back. Unmeasured (0) counts as room.
export const findBarCramped = (chatWidth: number, clear: number) =>
  chatWidth > 0 && chatWidth - clear - 2 * FIND_BAR_INSET < FIND_BAR_MIN;

/// Whether a push that takes `room` from the chat's right end keeps the transcript's column at the
/// width it has in the whole pane (model.ts transcriptColumn): only the gutters shrink, so the column
/// moves left and no line of the chat wraps anew. While it pushes, the page pins the column to that
/// width (sessionInfo.css --acpmux-session-info-column), so no frame of the slide narrows it either.
// While it pushes, the page pins the column to its whole-pane width and centers it, unrounded, in the
// chat beside the panel (sessionInfo.css): so a push keeps the column whenever that width and the two
// minimum page edges fit in the chat. The column's own width scales with the pane between its 720px
// floor and 800px cap, and the old exact-width check refused every push there, so the panel lay over
// the prompts instead (Lucas, 2026-11-06: "we should also shift the chat to the left so that the
// session summary doesnt overlap with prompts", as Codex's panel shifts its chat).
export const pushKeepsColumn = (paneWidth: number, room: number, column?: ChatColumn) =>
  paneWidth <= 0 ||
  room <= 0 ||
  (room < paneWidth &&
    paneWidth - room >= transcriptColumn(paneWidth, column).width + 2 * transcriptColumn(0, column).inset);

/// Where the pinned column (its whole-pane width, `pinned`) ends in a chat `chatWidth` wide: centered,
/// unrounded, never nearer the chat's sides than the page edge (sessionInfo.css).
const pinnedColumnEnd = (chatWidth: number, pinned: number, edge: number) =>
  chatWidth - Math.max(edge, (chatWidth - pinned) / 2);

/// Whether Session Info pushes the chat aside (sessionInfoStage `push`).
export const sessionInfoPushes = (
  placement: SessionInfoPlacement,
  pane: { width: number; height: number },
  width: number,
  column?: ChatColumn,
  wide = false,
  overflow = 0,
) => sessionInfoStage(placement, pane, width, column, wide, overflow) === "push";

/// Where the transcript's column ends in a chat `chatWidth` wide (model.ts transcriptColumn): it never
/// moves right as the chat widens.
const columnEnd = (chatWidth: number, column?: ChatColumn) => chatWidth - transcriptColumn(chatWidth, column).inset;

/// A room stepped in 8px increments while the column needs only part of the panel: the column's inset is
/// on the 4 grid (model.ts transcriptColumn, design/grid.md 5.5), so the centered column keeps its width.
/// The room a pushed panel `panel` wide (pushedWidth) takes from the chat's right end: by default only
/// what the gutter lacks, so the chat narrows gradually from the pane width where the gutter stops
/// holding the panel (0 there) to the panel and its margin (Leo, 2026-11-03: "gradually pushing into the
/// chat layout"). It is the least room that keeps the transcript's column, and `overflow` past it, a
/// margin clear of the panel. With `full` (Settings Push always), the panel and its margin.
export const pushedRoom = (paneWidth: number, panel: number, column?: ChatColumn, overflow = 0, full = false) => {
  const all = panel + FLOAT_MARGIN;
  if (paneWidth <= 0) return all;
  // Panel widths are user-controlled and may be any pixel value. Keep the panel's own 8px inset exact
  // instead of rounding the whole room up: an odd drag width must not leave a gap (#33865).
  if (full) return all;
  // Pushed, the column keeps its whole-pane width, centered in the chat (pinnedColumnEnd). It takes
  // only the room the gutter lacks, never the whole panel's where less clears it (Leo, 2026-11-09: "You
  // only push when you don't have any space left").
  const pinned = transcriptColumn(paneWidth, column).width;
  const edge = transcriptColumn(0, column).inset;
  const end = paneWidth - panel - 2 * FLOAT_MARGIN - Math.max(0, overflow);
  if (columnEnd(paneWidth, column) <= end) return 0;
  if (paneWidth - all <= 0 || pinnedColumnEnd(paneWidth - all, pinned, edge) > end) return all;
  // Else the least room, in steps of 2, whose column still ends by `end`. The column's inset is a whole
  // pixel (model.ts transcriptColumn), so a coarser step lets a 1 px wider panel flip between push and
  // overlay during a drag. At most about 300 steps, run once per layout of the panel.
  let room = 2;
  while (room < all && pinnedColumnEnd(paneWidth - room, pinned, edge) > end) room += 2;
  // Once the chat would end under the panel itself (its page edge under the card), the whole room: the
  // chat's right edge, its scrollbar with it, is then the panel's left margin, as Push always draws it.
  // A room within the margin of the panel is the whole room too.
  return room > panel - FLOAT_MARGIN ? all : room;
};
/// The chat's content Session Info must never float over: the transcript's rows and the composer.
const CHAT_CONTENT = ".acpmux-main :is(.acpmux-row, .acpmux-composer-box)";

/// How far the chat's drawn content reaches past the right end of the column the model expects for a
/// chat `chatWidth` wide (the chat's width less the transcript's gutter, from the shell's left edge); 0
/// when it stays inside. Read while the panel floats (the chat has the pane's full width) or pushes by
/// less than its full room (pushedRoom), with the chat's width now; the caller keeps the largest reading
/// until the panel closes, so a push it causes never undoes it.
/// While pushed (`pinnedFrom`, the pane's width), the column is the pinned one, its whole-pane width
/// centered in the chat (pinnedColumnEnd): measured against the chat's own narrower column, every row
/// read as reaching past it, and the push took more room than it needed.
export function chatContentOverflow(
  shell: HTMLElement,
  chatWidth: number,
  column?: ChatColumn,
  pinnedFrom?: number,
): number {
  if (chatWidth <= 0) return 0;
  const left = shell.getBoundingClientRect().left;
  const end =
    pinnedFrom && pinnedFrom > chatWidth
      ? pinnedColumnEnd(chatWidth, transcriptColumn(pinnedFrom, column).width, transcriptColumn(0, column).inset)
      : columnEnd(chatWidth, column);
  let reach = 0;
  for (const element of shell.querySelectorAll<HTMLElement>(CHAT_CONTENT)) {
    const { right, width } = element.getBoundingClientRect();
    if (width > 0) reach = Math.max(reach, right - left);
  }
  // Under half a pixel is the shell's sub-pixel offset, not content under the panel.
  return Math.max(0, Math.floor(reach - end + 0.5));
}

/// Whether Session Info shows: on (Debug Settings `agent.sessionInfo`), open (the viewer's, in every
/// chat tab), not stepped aside for a diff split, and only over the chat: never while a view takes
/// the pane in its place (`covered`: a turn's diff in place hides the header, and the toggle with it).
export const sessionInfoShown = ({
  on,
  open,
  suppressed = false,
  covered = false,
}: {
  on: boolean;
  open: boolean;
  suppressed?: boolean;
  covered?: boolean;
}) => on && open && !suppressed && !covered;

/// The side panel beside the chat (conversation/ArtifactPanel.tsx), a child of the pane's shell, or
/// the Background tasks column (backgroundTasks/BackgroundTasksPanel.tsx), which docks under it or
/// stands in its place at the same width.
export const SIDE_PANEL = ":scope > .acpmux-artifact, :scope > .acpmux-bg";

/// Session Info starts right below the header: the pane's tab row when the header is in it.
export function sessionInfoTopOffset(tabRowHeight: number): string {
  return tabRowHeight > 0 ? `${tabRowHeight}px` : "var(--acpmux-header-height, 28px)";
}

/// The chat's room in the pane: the pane's width less the side panel's beside the chat, and that
/// panel's width, which the floating Session Info keeps clear of.
export type PaneRoom = { width: number; side: number; height: number };
export function paneRoom(shell: HTMLElement): PaneRoom {
  const side = shell.querySelector<HTMLElement>(SIDE_PANEL)?.offsetWidth ?? 0;
  return { width: Math.max(0, shell.clientWidth - side), side, height: shell.clientHeight };
}

/// How the panel lays out its sections. Leo, 2026-10-22: "and this session rail is tmi and too many
/// boxes?". It drew eight hairline cards: two of them one line each (Context, Connectors), two of them
/// the same kind of thing (Servers and Background tasks, both background commands). No section is a
/// card now, and Servers' rows head Background tasks. The three ways the gallery shows
/// (`agent-pane.chat-inspector` `layout-*`):
/// - `glance`, shipped: three blocks with a hairline between them and no box. Where it runs: the
///   Environment's rows with no title over them, then Context and Connectors as one row each, which
///   open in place. What it made: Changes, Outputs. What it runs: Subagents, Background tasks.
/// - `rules`: every section keeps its title, Environment's too, with a hairline between each.
/// - `groups`: the same three blocks as `glance`, each one hairline card.
export type RailLayout = "glance" | "rules" | "groups";
export const RAIL_LAYOUT: RailLayout = "glance";

export const SESSION_INFO_TOGGLE = "button.acpmux-session-info-toggle";
/// What a press may land on without hiding the popover: a menu, popup or dialog the panel opened,
/// drawn outside it in a portal.
export const DISMISS_KEEPERS =
  'dialog[open], [role="dialog"], [role="alertdialog"], [role="menu"], [role="listbox"], .ui-popup';

/// The tool calls in `rows`, by id.
export const toolCallIds = (rows: readonly AcpmuxRow[]): ReadonlySet<string> =>
  new Set(rows.flatMap((row) => (row.items ?? []).flatMap((item) => (item.tool?.id ? [item.tool.id] : []))));

/// An Outputs file opens as the reply's path chip opens it (`link.openPath`); false when the host
/// refused it.
export const openOutputFile = (path: string) => tryChipHost("link.openPath", { path });
