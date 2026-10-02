// Rooms and the mini window, on the sidebar prototype (#16688). A room
// (plans/cmux-next/data-model.md 3-7) is a switchable set of workspaces with a color and a default
// browser profile, switched by the dots at the bottom of the sidebar. In the mini window, a link
// opened from a terminal, an agent or another app shows in a small window first,
// and one key promotes it to a tab of the workspace it came from.
import {
  agent,
  browser,
  findOpen,
  openFromHistory,
  seedStack,
  terminal,
  workspace,
  type Stack,
  type Workspace,
} from "./workspaces";

export type BrowserProfile = { id: string; name: string; color: RoomColor };
/** Catppuccin accent names; the page maps each to a `--proto-<name>` token. */
export type RoomColor = "mauve" | "peach" | "green" | "sky" | "overlay";
export type Room = { id: string; name: string; color?: RoomColor; browserProfile: string; stack: Stack };
export type Rooms = { rooms: Room[]; activeId: string };

export const browserProfiles: BrowserProfile[] = [
  { id: "default", name: "Default", color: "overlay" },
  { id: "work", name: "Manaflow", color: "mauve" },
  { id: "atlas", name: "Atlas client", color: "peach" },
  { id: "personal", name: "Personal", color: "sky" },
];
export const browserProfileById = new Map(browserProfiles.map((profile) => [profile.id, profile]));

/** Four rooms over the #16642 fixture: the cmux stack from #16695 plus a client, billing and home. */
export const seedRooms: Rooms = {
  activeId: "room-cmux",
  rooms: [
    { id: "room-cmux", name: "cmux", color: "mauve", browserProfile: "work", stack: seedStack },
    {
      id: "room-atlas",
      name: "Atlas",
      color: "peach",
      browserProfile: "atlas",
      stack: {
        activeId: "ws-atlas-light",
        workspaces: [
          workspace(
            "ws-atlas-light",
            agent("mock-light-theme", "Add light theme screenshots"),
            terminal("t-atlas-light", "atlas-web · bun dev"),
            browser("b-atlas-staging", "Atlas staging", "staging.atlas.dev/settings"),
          ),
          workspace("ws-atlas-design", browser("b-atlas-design", "Atlas design review", "figma.com/design/atlas-web")),
          workspace(
            "ws-atlas-api",
            terminal("t-atlas-api", "atlas-api · cargo run"),
            browser("b-atlas-api", "API docs", "localhost:8080/docs"),
          ),
        ],
      },
    },
    {
      id: "room-billing",
      name: "Billing",
      color: "green",
      browserProfile: "work",
      stack: {
        activeId: "ws-prorate",
        workspaces: [
          workspace(
            "ws-prorate",
            agent("mock-prorate", "Prorate seat changes mid-cycle"),
            browser("b-prorate", "Stripe test dashboard", "dashboard.stripe.com/test/subscriptions"),
          ),
          workspace(
            "ws-webhooks",
            agent("mock-webhooks", "Retry failed Stripe webhooks"),
            terminal("t-webhooks", "stripe listen"),
          ),
        ],
      },
    },
    {
      id: "room-home",
      name: "Home",
      browserProfile: "personal",
      stack: {
        activeId: "ws-zsh",
        workspaces: [
          workspace("ws-zsh", agent("mock-zsh", "Clean up zsh startup time"), terminal("t-zsh", "zsh · hyperfine")),
          workspace("ws-ghostty", agent("mock-ghostty-config", "Sync Ghostty config across machines")),
          workspace("ws-reading", browser("b-reading", "Reading list", "news.ycombinator.com")),
        ],
      },
    },
  ],
};

export const activeRoom = (rooms: Rooms) => rooms.rooms.find((room) => room.id === rooms.activeId)!;

export function switchRoom(rooms: Rooms, roomId: string): Rooms {
  return rooms.rooms.some((room) => room.id === roomId) ? { ...rooms, activeId: roomId } : rooms;
}

/** Next or previous room, wrapping (Cmd-Opt-] and Cmd-Opt-[). */
export function stepRoom(rooms: Rooms, step: 1 | -1): Rooms {
  const index = rooms.rooms.findIndex((room) => room.id === rooms.activeId);
  const next = rooms.rooms[(index + step + rooms.rooms.length) % rooms.rooms.length]!;
  return { ...rooms, activeId: next.id };
}

/** Replaces the active room's stack. */
export function withStack(rooms: Rooms, stack: Stack): Rooms {
  return { ...rooms, rooms: rooms.rooms.map((room) => (room.id === rooms.activeId ? { ...room, stack } : room)) };
}

/** Opening a history row: a session open in any room jumps there, switching rooms; else it is restored in the current room. */
export function openFromHistoryInRooms(
  rooms: Rooms,
  session: { sessionId: string; displayTitle?: string },
): { rooms: Rooms; jumped: boolean } {
  const holder = rooms.rooms.find((room) => findOpen(room.stack, session.sessionId));
  const target = holder ?? activeRoom(rooms);
  const result = openFromHistory(target.stack, session);
  const switched = { ...rooms, activeId: target.id };
  return { jumped: result.jumped, rooms: withStack(switched, result.stack) };
}

/** A new browser tab's profile: the workspace's own, else its room's (data-model.md 5). */
export const effectiveBrowserProfile = (room: Room, workspace: Workspace) =>
  workspace.browserProfile ?? room.browserProfile;

export type LinkSource = { kind: "terminal" | "agent" | "app"; label: string };
/** A link shown in the mini window: where it came from, which workspace it promotes into, and its profile. */
export type MiniWindow = {
  url: string;
  title: string;
  source: LinkSource;
  roomId: string;
  workspaceId: string;
  browserProfile: string;
};

/** Opens a link in the mini window. It belongs to the workspace the link came from (another app's link: the current one). */
export function openMini(
  rooms: Rooms,
  link: { url: string; title: string },
  source: LinkSource,
  from?: { roomId: string; workspaceId: string },
): MiniWindow {
  const room = rooms.rooms.find((candidate) => candidate.id === from?.roomId) ?? activeRoom(rooms);
  const target =
    room.stack.workspaces.find((candidate) => candidate.id === from?.workspaceId) ??
    room.stack.workspaces.find((candidate) => candidate.id === room.stack.activeId)!;
  return {
    ...link,
    source,
    roomId: room.id,
    workspaceId: target.id,
    browserProfile: effectiveBrowserProfile(room, target),
  };
}

let promoted = 0;

/** Promotes the mini window (Cmd-O): a browser tab after the active tab of its workspace, keeping its profile, shown at once. */
export function promoteMini(rooms: Rooms, mini: MiniWindow): { rooms: Rooms; tabId: string } {
  const tabId = `b-promoted-${++promoted}`;
  const tab = { ...browser(tabId, mini.title, mini.url), browserProfile: mini.browserProfile };
  return {
    tabId,
    rooms: {
      activeId: mini.roomId,
      rooms: rooms.rooms.map((room) =>
        room.id !== mini.roomId
          ? room
          : {
              ...room,
              stack: {
                activeId: mini.workspaceId,
                workspaces: room.stack.workspaces.map((candidate) => {
                  if (candidate.id !== mini.workspaceId) return candidate;
                  const after = candidate.tabs.findIndex((existing) => existing.id === candidate.activeTabId) + 1;
                  const tabs = [...candidate.tabs.slice(0, after), tab, ...candidate.tabs.slice(after)];
                  return { ...candidate, tabs, activeTabId: tabId };
                }),
              },
            },
      ),
    },
  };
}
