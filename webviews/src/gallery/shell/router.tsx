// The gallery shell's routes (TanStack Router, hash history so the static build works under any
// folder): `#/<entry>/<variant>?<controls>`. The search params are the gallery's URL contract
// (env.ts) plus `view`, validated on every navigation, and written without their defaults, so a
// view has one short shareable URL and Back and Forward walk the views.
import {
  createHashHistory,
  createRootRoute,
  createRoute,
  createRouter,
  Outlet,
  redirect,
  type RouterHistory,
} from "@tanstack/react-router";
import { readEnv, writeEnv, type GalleryEnv } from "../env";
import { entries } from "../registry";

export const VIEWS = ["variant", "variants", "locales", "themes"] as const;
export type View = (typeof VIEWS)[number];
export type ShellSearch = GalleryEnv & { view: View };

/** Search params as flat strings, the way the stage frames and the matrix read them. */
function parseSearch(text: string): Record<string, unknown> {
  return Object.fromEntries(new URLSearchParams(text));
}

function stringifySearch(search: Record<string, unknown>): string {
  const params = writeEnv(readEnv(new URLSearchParams(search as Record<string, string>)));
  const view = search.view;
  if (typeof view === "string" && view !== "variant" && (VIEWS as readonly string[]).includes(view))
    params.set("view", view);
  const text = params.toString();
  return text ? `?${text}` : "";
}

export function validateShellSearch(raw: Record<string, unknown>): ShellSearch {
  const strings = Object.fromEntries(
    Object.entries(raw).map(([key, value]) => [key, typeof value === "string" ? value : String(value)]),
  );
  const view = (VIEWS as readonly string[]).includes(strings.view ?? "") ? (strings.view as View) : "variant";
  return { ...readEnv(new URLSearchParams(strings)), view };
}

const firstVariant = (entryId: string) => {
  const entry = entries.find((candidate) => candidate.id === entryId);
  return entry ? Object.keys(entry.variants)[0] : undefined;
};

export function createGalleryRouter(Layout: () => React.ReactNode, history?: RouterHistory) {
  const rootRoute = createRootRoute({ component: Layout });
  const indexRoute = createRoute({
    getParentRoute: () => rootRoute,
    path: "/",
    validateSearch: validateShellSearch,
    beforeLoad: ({ search }) => {
      const entry = entries[0];
      if (entry)
        throw redirect({
          href: `/${encodeURIComponent(entry.id)}/${encodeURIComponent(firstVariant(entry.id)!)}${stringifySearch(search)}`,
        });
    },
    component: Outlet,
  });
  const entryRoute = createRoute({
    getParentRoute: () => rootRoute,
    path: "/$entry",
    validateSearch: validateShellSearch,
    beforeLoad: ({ params, search }) => {
      const variant = firstVariant(params.entry);
      if (variant)
        throw redirect({
          href: `/${encodeURIComponent(params.entry)}/${encodeURIComponent(variant)}${stringifySearch(search)}`,
        });
    },
    component: Outlet,
  });
  const variantRoute = createRoute({
    getParentRoute: () => rootRoute,
    path: "/$entry/$variant",
    validateSearch: validateShellSearch,
    component: Outlet,
  });
  const routeTree = rootRoute.addChildren([indexRoute, entryRoute, variantRoute]);
  const router = createRouter({ history: history ?? createHashHistory(), routeTree, parseSearch, stringifySearch });
  return { router, variantRoute };
}

export type GalleryRouter = ReturnType<typeof createGalleryRouter>["router"];
