// Hash-history routes: `#/settings/<section>?focus=<key>`. Navigation goes through the
// router's history (push, back, forward), so Cmd-[ / Cmd-] walk the page history.
import {
  createBrowserHistory,
  createRootRoute,
  createRoute,
  createRouter,
  type AnyRouter,
  type RouterHistory,
} from "@tanstack/react-router";
import type { ReactNode } from "react";
import { categoryOf, homes } from "./categories";

export function createSettingsRouter(Component: () => ReactNode, history?: RouterHistory): AnyRouter {
  const rootRoute = createRootRoute({ component: Component, notFoundComponent: () => null });
  const routeTree = rootRoute.addChildren([
    createRoute({ getParentRoute: () => rootRoute, path: "/" }),
    createRoute({ getParentRoute: () => rootRoute, path: "/settings" }),
    createRoute({ getParentRoute: () => rootRoute, path: "/settings/$section" }),
  ]);
  return createRouter({ history: history ?? createFragmentHistory(), routeTree }) as unknown as AnyRouter;
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
export type SettingsLocation = { section: string; focus: string | null; workspace: string | null };

/**
 * The category and focused key of a router href such as `/settings/appearance?focus=a.b`. The path
 * names a category or a schema section (old links and `app settings <section>`); a focused key
 * opens the category that holds its row.
 */
export function parseLocation(href: string): SettingsLocation {
  const url = new URL(href, "settings://page");
  const match = /^\/settings\/([^/]+)/.exec(url.pathname);
  const focus = url.searchParams.get("focus");
  const home = focus ? homes.get(focus) : undefined;
  const section = home?.category ?? categoryOf(match ? decodeURIComponent(match[1]!) : undefined);
  return { section, focus, workspace: url.searchParams.get("workspace") };
}

export function sectionHref(section: string, focus?: string | null, workspace?: string | null): string {
  const query = new URLSearchParams();
  if (focus) query.set("focus", focus);
  if (workspace) query.set("workspace", workspace);
  const search = query.toString();
  return `/settings/${encodeURIComponent(section)}${search ? `?${search}` : ""}`;
}
