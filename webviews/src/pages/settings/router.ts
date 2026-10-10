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
import { defaultSection, isSection } from "./schema";

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

/** The section and focused key of a router href such as `/settings/appearance?focus=a.b`. */
export function parseLocation(href: string): SettingsLocation {
  const url = new URL(href, "settings://page");
  const match = /^\/settings\/([^/]+)/.exec(url.pathname);
  const section = match ? decodeURIComponent(match[1]!) : undefined;
  return { section: isSection(section) ? section : defaultSection, focus: url.searchParams.get("focus") };
}

export function sectionHref(section: string, focus?: string | null): string {
  return `/settings/${encodeURIComponent(section)}${focus ? `?focus=${encodeURIComponent(focus)}` : ""}`;
}
