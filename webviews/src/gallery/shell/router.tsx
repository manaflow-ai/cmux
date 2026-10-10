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
import { readCompare, writeCompare, type CompareState } from "../compare";
import { readEnv, writeEnv, type GalleryEnv } from "../env";
import { readTunes, writeTunes } from "../../experiments/tunable";
import { readyEntries } from "../entryStore";
import { entryStore } from "../registry";

export const VIEWS = ["variant", "variants", "locales", "themes", "compare", "browse"] as const;
export type View = (typeof VIEWS)[number];
/**
 * The controls, the view, the compare view's state (compare.ts; written only in that view), and
 * the edited tunables (experiments/tunable.ts; web only, so not in env.ts's shared contract).
 */
export type ShellSearch = GalleryEnv & { view: View; compare: CompareState; tune: string };

/** Search params as flat strings, the way the stage frames and the matrix read them. */
function parseSearch(text: string): Record<string, unknown> {
  return Object.fromEntries(new URLSearchParams(text));
}

function stringifySearch(search: Record<string, unknown>): string {
  const flat = Object.fromEntries(
    Object.entries(search).flatMap(([key, value]) =>
      key === "compare" && value && typeof value === "object"
        ? [...writeCompare(value as CompareState)]
        : [[key, typeof value === "string" ? value : String(value)]],
    ),
  );
  const params = writeEnv(readEnv(new URLSearchParams(flat)));
  const view = search.view;
  if (typeof view === "string" && view !== "variant" && (VIEWS as readonly string[]).includes(view))
    params.set("view", view);
  if (view === "compare") writeCompare(readCompare(new URLSearchParams(flat)), params);
  const tune = writeTunes(readTunes(flat.tune ?? ""));
  if (tune) params.set("tune", tune);
  const text = params.toString();
  return text ? `?${text}` : "";
}

export function validateShellSearch(raw: Record<string, unknown>): ShellSearch {
  const strings = Object.fromEntries(
    Object.entries(raw).map(([key, value]) => [key, typeof value === "string" ? value : String(value)]),
  );
  const view = (VIEWS as readonly string[]).includes(strings.view ?? "") ? (strings.view as View) : "variant";
  const params = new URLSearchParams(strings);
  const compare =
    raw.compare && typeof raw.compare === "object"
      ? readCompare(writeCompare(raw.compare as CompareState))
      : readCompare(params);
  return { ...readEnv(params), view, compare, tune: writeTunes(readTunes(strings.tune ?? "")) };
}

/** The entry's first variant, once every entry file has loaded or failed (each loads on its own). */
async function firstVariant(entryId: string): Promise<string | undefined> {
  const entry = readyEntries(await entryStore.settled()).find((candidate) => candidate.id === entryId);
  return entry ? Object.keys(entry.variants)[0] : undefined;
}

export function createGalleryRouter(Layout: () => React.ReactNode, history?: RouterHistory) {
  const rootRoute = createRootRoute({ component: Layout });
  const indexRoute = createRoute({
    getParentRoute: () => rootRoute,
    path: "/",
    validateSearch: validateShellSearch,
    beforeLoad: async ({ search }) => {
      const entry = readyEntries(await entryStore.settled())[0];
      if (entry)
        throw redirect({
          href: `/${encodeURIComponent(entry.id)}/${encodeURIComponent(Object.keys(entry.variants)[0]!)}${stringifySearch(search)}`,
        });
    },
    component: Outlet,
  });
  const entryRoute = createRoute({
    getParentRoute: () => rootRoute,
    path: "/$entry",
    validateSearch: validateShellSearch,
    beforeLoad: async ({ params, search }) => {
      const variant = await firstVariant(params.entry);
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
