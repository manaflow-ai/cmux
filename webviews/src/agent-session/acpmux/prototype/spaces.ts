// Spaces and the mini window, on the sidebar prototype (#16688). A space
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

export type BrowserProfile = { id: string; name: string; color: SpaceColor };
/** Catppuccin accent names; the page maps each to a `--proto-<name>` token. */
export type SpaceColor = "mauve" | "peach" | "green" | "sky" | "overlay";
export type Space = { id: string; name: string; color?: SpaceColor; browserProfile: string; stack: Stack };
export type Spaces = { spaces: Space[]; activeId: string };

export const browserProfiles: BrowserProfile[] = [
  { id: "default", name: "Default", color: "overlay" },
  { id: "work", name: "Manaflow", color: "mauve" },
  { id: "atlas", name: "Atlas client", color: "peach" },
  { id: "personal", name: "Personal", color: "sky" },
];
export const browserProfileById = new Map(browserProfiles.map((profile) => [profile.id, profile]));

/** Four spaces over the #16642 fixture: the cmux stack from #16695 plus a client, billing and home. */
export const seedSpaces: Spaces = {
  activeId: "space-cmux",
  spaces: [
    { id: "space-cmux", name: "cmux", color: "mauve", browserProfile: "work", stack: seedStack },
    {
      id: "space-atlas",
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
      id: "space-billing",
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
      id: "space-home",
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

export const activeSpace = (spaces: Spaces) => spaces.spaces.find((space) => space.id === spaces.activeId)!;

export function switchSpace(spaces: Spaces, spaceId: string): Spaces {
  return spaces.spaces.some((space) => space.id === spaceId) ? { ...spaces, activeId: spaceId } : spaces;
}

/** Next or previous space, wrapping (Cmd-Opt-] and Cmd-Opt-[). */
export function stepSpace(spaces: Spaces, step: 1 | -1): Spaces {
  const index = spaces.spaces.findIndex((space) => space.id === spaces.activeId);
  const next = spaces.spaces[(index + step + spaces.spaces.length) % spaces.spaces.length]!;
  return { ...spaces, activeId: next.id };
}

/** Replaces the active space's stack. */
export function withStack(spaces: Spaces, stack: Stack): Spaces {
  return { ...spaces, spaces: spaces.spaces.map((space) => (space.id === spaces.activeId ? { ...space, stack } : space)) };
}

/** Opening a history row: a session open in any space jumps there, switching spaces; else it is restored in the current space. */
export function openFromHistoryInSpaces(
  spaces: Spaces,
  session: { sessionId: string; displayTitle?: string },
): { spaces: Spaces; jumped: boolean } {
  const holder = spaces.spaces.find((space) => findOpen(space.stack, session.sessionId));
  const target = holder ?? activeSpace(spaces);
  const result = openFromHistory(target.stack, session);
  const switched = { ...spaces, activeId: target.id };
  return { jumped: result.jumped, spaces: withStack(switched, result.stack) };
}

/** A new browser tab's profile: the workspace's own, else its space's (data-model.md 5). */
export const effectiveBrowserProfile = (space: Space, workspace: Workspace) =>
  workspace.browserProfile ?? space.browserProfile;

export type LinkSource = { kind: "terminal" | "agent" | "app"; label: string };
/** A link shown in the mini window: where it came from, which workspace it promotes into, and its profile. */
export type MiniWindow = {
  url: string;
  title: string;
  source: LinkSource;
  spaceId: string;
  workspaceId: string;
  browserProfile: string;
};

/** Opens a link in the mini window. It belongs to the workspace the link came from (another app's link: the current one). */
export function openMini(
  spaces: Spaces,
  link: { url: string; title: string },
  source: LinkSource,
  from?: { spaceId: string; workspaceId: string },
): MiniWindow {
  const space = spaces.spaces.find((candidate) => candidate.id === from?.spaceId) ?? activeSpace(spaces);
  const target =
    space.stack.workspaces.find((candidate) => candidate.id === from?.workspaceId) ??
    space.stack.workspaces.find((candidate) => candidate.id === space.stack.activeId)!;
  return {
    ...link,
    source,
    spaceId: space.id,
    workspaceId: target.id,
    browserProfile: effectiveBrowserProfile(space, target),
  };
}

let promoted = 0;

/** Promotes the mini window (Cmd-O): a browser tab after the active tab of its workspace, keeping its profile, shown at once. */
export function promoteMini(spaces: Spaces, mini: MiniWindow): { spaces: Spaces; tabId: string } {
  const tabId = `b-promoted-${++promoted}`;
  const tab = { ...browser(tabId, mini.title, mini.url), browserProfile: mini.browserProfile };
  return {
    tabId,
    spaces: {
      activeId: mini.spaceId,
      spaces: spaces.spaces.map((space) =>
        space.id !== mini.spaceId
          ? space
          : {
              ...space,
              stack: {
                activeId: mini.workspaceId,
                workspaces: space.stack.workspaces.map((candidate) => {
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
