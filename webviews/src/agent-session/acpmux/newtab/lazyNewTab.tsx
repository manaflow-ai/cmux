import { type ComponentProps, useEffect, useSyncExternalStore } from "react";

// The two New Tab screens (NewTabScreen and the classic NewTabPage) load from their own chunk, not
// from the chat page's first script: a restored chat's first paint never draws them. The chunk
// loads the moment a pane shows New Tab, and otherwise at the first idle moment after the page
// has drawn, so a later Cmd-T draws New Tab in its first frame. A screen mounted before its chunk
// arrives draws nothing for those few milliseconds, then mounts once; a failed load is retried on
// the next mount or preload, never cached as broken.

type NewTabModules = {
  screen: typeof import("./NewTabScreen");
  page: typeof import("../NewTabPage");
};

let loaded: NewTabModules | undefined;
let pending: Promise<NewTabModules> | undefined;
const listeners = new Set<() => void>();

/// Starts (or joins) the New Tab chunk's load.
export function loadNewTab(): Promise<NewTabModules> {
  if (loaded) return Promise.resolve(loaded);
  pending ??= Promise.all([import("./NewTabScreen"), import("../NewTabPage")]).then(
    ([screen, page]) => {
      loaded = { screen, page };
      for (const listener of listeners) listener();
      return loaded;
    },
    (error: unknown) => {
      pending = undefined;
      throw error;
    },
  );
  return pending;
}

/// Loads the chunk at the first idle moment after the page has drawn (no-op once loaded).
export function preloadNewTabWhenIdle(): void {
  if (loaded || pending || typeof window === "undefined") return;
  const start = () => void loadNewTab().catch(() => undefined);
  if (typeof window.requestIdleCallback === "function") window.requestIdleCallback(start, { timeout: 2000 });
  else setTimeout(start, 200);
}

function subscribe(listener: () => void): () => void {
  listeners.add(listener);
  return () => listeners.delete(listener);
}

const current = () => loaded;

function useNewTabModules(): NewTabModules | undefined {
  const modules = useSyncExternalStore(subscribe, current, current);
  useEffect(() => {
    if (!modules) void loadNewTab().catch(() => undefined);
  }, [modules]);
  return modules;
}

type ScreenProps = ComponentProps<typeof import("./NewTabScreen").NewTabScreen>;
type PageProps = ComponentProps<typeof import("../NewTabPage").NewTabPage>;

/// NewTabScreen from its chunk: nothing until the chunk has loaded.
export function LazyNewTabScreen(props: ScreenProps) {
  const modules = useNewTabModules();
  return modules ? <modules.screen.NewTabScreen {...props} /> : null;
}

/// The classic NewTabPage from the same chunk: nothing until the chunk has loaded.
export function LazyNewTabPage(props: PageProps) {
  const modules = useNewTabModules();
  return modules ? <modules.page.NewTabPage {...props} /> : null;
}
