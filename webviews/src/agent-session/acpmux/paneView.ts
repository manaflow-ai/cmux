// One chat as a view of a shared pane document (goal memory-per-chat, cmux#51235): a pane's chats
// share one page, each its own view, so a hidden chat costs a view (about 5 to 13 MB) instead of a
// page (about 37 MB) and still shows again as a style change. The page host tells the views apart
// by a `view` field: every call a view makes carries it, every subscription filters on it, and an
// op the host calls on the page goes to the handler of the view it names.
//
// A page with no views (today's one chat a page) uses the base client as it is; `scopedPageClient`
// with a null view returns the base client unchanged, so nothing changes until a host mounts views.
import type { PageCallOptions, PageClient, PageEventMeta, PageHandler } from "../../pages/shared/pageClient";
import { pageError } from "../../pages/shared/pageClient";

/// The params field that names the view a call, subscription or host call is for.
export const VIEW_FIELD = "view";

type Routes = { base: PageClient; byOp: Map<string, { views: Map<string | null, PageHandler>; off: () => void }> };
const routesByBase = new WeakMap<PageClient, Routes>();

function routesOf(base: PageClient): Routes {
  let routes = routesByBase.get(base);
  if (!routes) {
    routes = { base, byOp: new Map() };
    routesByBase.set(base, routes);
  }
  return routes;
}

function viewOf(params: unknown): string | null {
  if (!params || typeof params !== "object") return null;
  const view = (params as Record<string, unknown>)[VIEW_FIELD];
  return typeof view === "string" ? view : null;
}

/// Registers `handler` for `op` as `view` sees it. The base client gets one handler an op, which
/// sends each host call to the view its params name (no view: the page's own handler, null).
function handleForView(base: PageClient, view: string | null, op: string, handler: PageHandler): () => void {
  const routes = routesOf(base);
  let route = routes.byOp.get(op);
  if (!route) {
    const views = new Map<string | null, PageHandler>();
    const off = base.handle(op, (params) => {
      const target = views.get(viewOf(params));
      if (!target) throw pageError("cmux.agent.view.unknown", `no view ${String(viewOf(params))} serves ${op}`);
      return target(params);
    });
    route = { views, off };
    routes.byOp.set(op, route);
  }
  route.views.set(view, handler);
  const current = route;
  return () => {
    if (current.views.get(view) !== handler) return;
    current.views.delete(view);
    if (current.views.size > 0) return;
    current.off();
    routes.byOp.delete(op);
  };
}

function withView(params: unknown, view: string): Record<string, unknown> {
  if (params === undefined || params === null) return { [VIEW_FIELD]: view };
  if (typeof params !== "object" || Array.isArray(params))
    throw pageError("cmux.agent.view.params", "a view's call takes an object of params");
  return { ...(params as Record<string, unknown>), [VIEW_FIELD]: view };
}

/// The client one view uses: its calls carry `view`, its subscriptions filter on it, and the ops it
/// serves answer only host calls naming it. A null view is the page itself: the base client.
export function scopedPageClient(base: PageClient, view: string | null): PageClient {
  if (view === null) return base;
  return {
    call<R>(op: string, params: unknown, options?: PageCallOptions): Promise<R> {
      return base.call<R>(op, withView(params, view), options);
    },
    subscribe<E>(
      stream: string,
      onEvent: (data: E, seq: number, meta?: PageEventMeta) => void,
      filter?: Record<string, unknown>,
    ): Promise<() => void> {
      return base.subscribe<E>(stream, onEvent, { ...filter, [VIEW_FIELD]: view });
    },
    handle(op: string, handler: PageHandler): () => void {
      return handleForView(base, view, op, handler);
    },
  };
}

/// The page's own handler for `op` on a base client that views share: use it instead of
/// `base.handle` once any view serves the same op, so a host call naming no view still reaches it.
export function handleForPage(base: PageClient, op: string, handler: PageHandler): () => void {
  return handleForView(base, null, op, handler);
}
