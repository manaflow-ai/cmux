// The changed module is transformed as soon as the watcher sees the save, not after the page asks.
// Vite transforms a module when a request for it arrives: on a save it sends the hot update, the
// page's client gets it, fetches `File.tsx?t=…`, and only then does the React Compiler / import
// analysis / Refresh pass run, so a save waits for the transform after the round trip. Starting the
// transform from the first hot-update hook overlaps it with the update message and the client's
// fetch. The page's request then joins the transform in flight (Vite's pending-request map, keyed by
// the URL without its `?t=`, keeps one whose start is after the file's invalidation) or reads its
// cached result, so the module is still transformed once per save.
// scripts/measure/dev-loop/web_swap.sh measures it; its bound already counts transform as waiting on
// the file event only. `CMUX_TRANSFORM_ON_CHANGE=off` leaves the transform to the page's request (an A/B).
import type { EnvironmentModuleNode, Plugin } from "vite-plus";

/** The modules of one save worth transforming before the page asks: JS a page has loaded (it has an
 *  importer or accepts itself), so a fetch for it will follow the update. */
export function modulesToTransformEarly(modules: readonly EnvironmentModuleNode[]): string[] {
  const urls = new Set<string>();
  for (const mod of modules) {
    if (mod.type !== "js" || !mod.url) continue;
    if (mod.importers.size === 0 && !mod.isSelfAccepting) continue;
    urls.add(mod.url);
  }
  return [...urls];
}

export function transformOnChange(): Plugin {
  return {
    name: "cmux-transform-on-change",
    apply: "serve",
    // First of the update hooks, so the transform starts before any other plugin's hook runs.
    enforce: "pre",
    hotUpdate: {
      order: "pre",
      handler({ type, modules }) {
        if (type !== "update" || this.environment.name !== "client") return;
        if (process.env.CMUX_TRANSFORM_ON_CHANGE === "off") return;
        const environment = this.environment as unknown as {
          transformRequest(url: string): Promise<unknown>;
        };
        for (const url of modulesToTransformEarly(modules as EnvironmentModuleNode[])) {
          // Not awaited: the update goes out while it runs. A failure is the page's to show, through
          // its own request for the module.
          environment.transformRequest(url).catch(() => {});
        }
      },
    },
  };
}
