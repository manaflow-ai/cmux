import { createElement, lazy, Suspense, useState, type ComponentType } from "react";

/// A view that loads in its own chunk, out of the page's first JavaScript (the pane's startup set),
/// with `preload` to fetch it before it is shown.
export type LazyView<P extends object> = ComponentType<P> & { preload: () => Promise<void> };

/// `load`'s component, loaded the first time it renders or `preload` runs. A view mounted after its
/// chunk arrived draws in the same frame as an eager one; one mounted before shows nothing until it
/// arrives. Each mount keeps the path it started with, so the chunk landing never remounts a view.
export function lazyView<P extends object>(load: () => Promise<ComponentType<P>>): LazyView<P> {
  let loaded: ComponentType<P> | undefined;
  let pending: Promise<ComponentType<P>> | undefined;
  const start = () =>
    (pending ??= load().then(
      (component) => (loaded = component),
      (error: unknown) => {
        // A failed fetch can be asked again (the next render or preload), not cached as broken.
        pending = undefined;
        throw error;
      },
    ));
  const Waiting = lazy(() => start().then((component) => ({ default: component })));
  function View(props: P) {
    const [ready] = useState(() => loaded);
    return ready
      ? createElement(ready, props)
      : createElement(Suspense, { fallback: null }, createElement(Waiting as ComponentType<P>, props));
  }
  View.preload = () => start().then(() => undefined);
  return View;
}

/// Preloads `views` one at a time, each at an idle moment, so a chat's open never shares its frames
/// with them. Returns a cancel; it stops on its own once every view is loaded.
export function preloadWhenIdle(views: readonly { preload: () => Promise<void> }[], timeout = 2000): () => void {
  let cancelled = false;
  let handle: number | undefined;
  const idle = globalThis.requestIdleCallback;
  const next = (index: number) => {
    if (cancelled || index >= views.length) return;
    const run = () => {
      handle = undefined;
      if (cancelled) return;
      void views[index]!.preload()
        .catch(() => undefined)
        .then(() => next(index + 1));
    };
    handle = idle ? idle(run, { timeout }) : (setTimeout(run, 0) as unknown as number);
  };
  next(0);
  return () => {
    cancelled = true;
    if (handle === undefined) return;
    if (idle) globalThis.cancelIdleCallback(handle);
    else clearTimeout(handle);
  };
}
