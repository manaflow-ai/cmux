// Hash-history routes: `#/settings/<section>?focus=<key>`. Navigation goes through the
// router's history (push, back, forward), so Cmd-[ / Cmd-] walk the page history.
import {
  createBrowserHistory,
  createRootRouteWithContext,
  createRoute,
  createRouter,
  type AnyRouter,
  type RouteComponent,
  type RouterHistory,
} from "@tanstack/react-router";
import type { QueryClient } from "@tanstack/react-query";
import { ensureSection, routeSection } from "./sectionQueries";
import type { SettingsStore } from "./store";

/** What every route's loader reads from: the page's query cache and its store. */
export type SettingsRouterContext = { queryClient: QueryClient; store: SettingsStore };

/** The route's search: the focused key, the workspace Change Background… came from, the sidebar
 * search's text (`q`) and its Changed filter (`changed=1`). Plain `?a=b` pairs, never JSON. */
export type SettingsSearch = { focus?: string; workspace?: string; q?: string; changed?: true };

export function validateSettingsSearch(raw: Record<string, unknown>): SettingsSearch {
  const text = (value: unknown) => (value === undefined || value === null || value === "" ? undefined : String(value));
  const out: SettingsSearch = {};
  const focus = text(raw.focus);
  const workspace = text(raw.workspace);
  const q = text(raw.q);
  if (focus) out.focus = focus;
  if (workspace) out.workspace = workspace;
  if (q) out.q = q;
  if (raw.changed === true || raw.changed === "1" || raw.changed === 1) out.changed = true;
  return out;
}

/** `?focus=a.b&q=x` as plain pairs (host links and sectionHref write them so). */
export function parseSettingsSearch(search: string): Record<string, unknown> {
  return Object.fromEntries(new URLSearchParams(search.startsWith("?") ? search.slice(1) : search));
}

export function stringifySettingsSearch(search: Record<string, unknown>): string {
  const query = new URLSearchParams();
  for (const [key, value] of Object.entries(search)) {
    if (value === undefined || value === null || value === "" || value === false) continue;
    query.set(key, value === true ? "1" : String(value));
  }
  const text = query.toString();
  return text ? `?${text}` : "";
}

/**
 * The page's router. The root route is the window (`layout`: the sidebar and the content column);
 * each section is a route whose loader ensures the host reads its cards draw from
 * (sectionQueries.ts). Links preload on intent (hover or keyboard focus), and the loader always
 * runs (the query cache, not the router, decides what is fresh), so a click on a hovered section
 * draws it complete in its first frame. While a slow read is out the previous section stays; after
 * `defaultPendingMs` the new section draws with what it has (`section` as the pending component).
 */
export function createSettingsRouter(
  options: { layout: RouteComponent; section: RouteComponent; context: SettingsRouterContext },
  history?: RouterHistory,
): AnyRouter {
  const rootRoute = createRootRouteWithContext<SettingsRouterContext>()({
    component: options.layout,
    notFoundComponent: () => null,
    validateSearch: validateSettingsSearch,
  });
  const sectionRoute = (path: "/" | "/settings" | "/settings/$section") =>
    createRoute({
      getParentRoute: () => rootRoute,
      path,
      // The focused key picks the section (a key's home), so it is a loader dependency; the
      // search text and the workspace are not.
      loaderDeps: ({ search }) => ({ focus: (search as SettingsSearch).focus }),
      loader: ({ context, params, deps }) =>
        ensureSection(
          context.queryClient,
          context.store,
          routeSection((params as { section?: string }).section, deps.focus),
        ),
      component: options.section,
      pendingComponent: options.section,
    });
  const routeTree = rootRoute.addChildren([
    sectionRoute("/"),
    sectionRoute("/settings"),
    sectionRoute("/settings/$section"),
  ]);
  return createRouter({
    history: history ?? createFragmentHistory(),
    routeTree,
    context: options.context,
    parseSearch: parseSettingsSearch,
    stringifySearch: stringifySettingsSearch,
    // Hover or keyboard focus on a link reads its section ahead of the click.
    defaultPreload: "intent",
    // The query cache owns freshness: every preload and navigation runs the loader, whose
    // ensureQueryData answers from the cache when it can.
    defaultPreloadStaleTime: 0,
    // A section whose read is slow shows after a short wait with what it has, and never holds
    // a pending state longer than it takes.
    defaultPendingMs: 150,
    defaultPendingMinMs: 0,
    defaultStructuralSharing: true,
  }) as unknown as AnyRouter;
}

/**
 * Browser history over the URL fragment alone: the route (`#/settings/<section>?focus=<key>`)
 * is the whole fragment, and the page's own query string is never part of it. TanStack's hash
 * history adds `location.search` to the route, so a host page with a query (the gallery stage's
 * `frame.html?entry=...`) turned `?focus=<key>` into `<key>?entry=...` and no row matched.
 */
export function createFragmentHistory(win: Window = window): RouterHistory {
  return createBrowserHistory({
    window: win,
    parseLocation: () => fragmentLocation(win.location.hash, win.history.state),
    createHref: (href) => `${win.location.pathname}${win.location.search}#${href}`,
  });
}

type FragmentLocation = RouterHistory["location"];

/** The route of a URL fragment (`#/settings/a?focus=b`), as TanStack's location. */
export function fragmentLocation(fragment: string, state: unknown): FragmentLocation {
  const href = fragment.replace(/^#/, "") || "/";
  const searchAt = href.indexOf("?");
  const key = Math.random().toString(36).slice(2, 9);
  return {
    href,
    pathname: searchAt === -1 ? href : href.slice(0, searchAt),
    search: searchAt === -1 ? "" : href.slice(searchAt),
    hash: "",
    state: (state as FragmentLocation["state"] | null) ?? { __TSR_index: 0, key, __TSR_key: key },
  } as FragmentLocation;
}

/** `workspace` is the workspace Change Background… came from (the picker's This Workspace). */
export type SettingsLocation = {
  section: string;
  focus: string | null;
  workspace: string | null;
  /** The sidebar search's text; empty when not searching. */
  query: string;
  /** Whether the search lists only changed settings. */
  changedOnly: boolean;
};

/**
 * The category and focused key of a router href such as `/settings/appearance?focus=a.b`. The path
 * names a category or a schema section (old links and `app settings <section>`); a focused key
 * opens the category that holds its row.
 */
export function parseLocation(href: string): SettingsLocation {
  const url = new URL(href, "settings://page");
  const match = /^\/settings\/([^/]+)/.exec(url.pathname);
  const focus = url.searchParams.get("focus");
  // The host can open an old or malformed deep link while Settings prepares its first screen.
  // An invalid percent escape is an unknown category, like any other unknown section ID.
  let requestedSection: string | undefined;
  if (match) {
    try {
      requestedSection = decodeURIComponent(match[1]!);
    } catch (error) {
      if (!(error instanceof URIError)) throw error;
    }
  }
  const section = routeSection(requestedSection, focus);
  return {
    section,
    focus,
    workspace: url.searchParams.get("workspace"),
    query: url.searchParams.get("q") ?? "",
    changedOnly: url.searchParams.get("changed") === "1",
  };
}

export function sectionHref(
  section: string,
  focus?: string | null,
  workspace?: string | null,
  filter?: { query?: string; changedOnly?: boolean },
): string {
  const query = new URLSearchParams();
  if (focus) query.set("focus", focus);
  if (workspace) query.set("workspace", workspace);
  if (filter?.query) query.set("q", filter.query);
  if (filter?.changedOnly) query.set("changed", "1");
  const search = query.toString();
  return `/settings/${encodeURIComponent(section)}${search ? `?${search}` : ""}`;
}
