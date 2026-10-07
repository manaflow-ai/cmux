// Hash-history routes: `#/settings/<section>?focus=<key>`. Navigation goes through the
// router's history (push, back, forward), so Cmd-[ / Cmd-] walk the page history.
import {
  createHashHistory,
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
  return createRouter({ history: history ?? createHashHistory(), routeTree }) as unknown as AnyRouter;
}

export type SettingsLocation = { section: string; focus: string | null };

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
  return { section: home?.category ?? categoryOf(match ? decodeURIComponent(match[1]!) : undefined), focus };
}

export function sectionHref(section: string, focus?: string | null): string {
  return `/settings/${encodeURIComponent(section)}${focus ? `?focus=${encodeURIComponent(focus)}` : ""}`;
}
