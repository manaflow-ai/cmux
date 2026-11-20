// What Home draws only when the person opens it: the Cmd-K palette, the route's sheets and the
// New/Edit Chief page, a run's sheet and a Chief's work pane. None is in the first viewport, so
// none is in the page's startup JS (about 190 KB of it: the palette's combobox, the Chief editor,
// the picture cropper). Each is its own chunk, fetched once the page is idle after its first
// frame (`preloadSheets`), so the first open normally finds it already loaded.
import { lazy } from "react";

const palette = () => import("./Palette");
const routeSheets = () => import("./RouteSheets");
const runSheet = () => import("./RunSheet");
const chiefWorkPane = () => import("./ChiefWorkPane");

/** The components above, each loaded on its first render (HomeChannelsPage draws each in a Suspense). */
export const lazySheets = {
  Palette: lazy(() => palette().then((module) => ({ default: module.Palette }))),
  RouteSheets: lazy(() => routeSheets().then((module) => ({ default: module.RouteSheets }))),
  ChiefRoutePage: lazy(() => routeSheets().then((module) => ({ default: module.ChiefRoutePage }))),
  RunSheet: lazy(() => runSheet().then((module) => ({ default: module.RunSheet }))),
  ChiefWorkPane: lazy(() => chiefWorkPane().then((module) => ({ default: module.ChiefWorkPane }))),
};

let preloaded = false;

/** Fetches every chunk above once, when the page is next idle (at most 2 s after the call). */
export function preloadSheets(): void {
  if (preloaded) return;
  preloaded = true;
  const load = () => {
    for (const chunk of [palette, routeSheets, runSheet, chiefWorkPane]) void chunk().catch(() => undefined);
  };
  if (typeof requestIdleCallback === "function") requestIdleCallback(load, { timeout: 2000 });
  else setTimeout(load, 0);
}
