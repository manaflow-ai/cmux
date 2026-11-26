// Dev servers only: serve a JSON import without a source map, as upstream Vite does.
//
// vite-plus-core 1.3.0's native JSON transform (`builtin:vite-json`) returns its "no map" as
// `{ inner: { mappings: "" } }`. The dev server's map chain reads that as a map it can't combine
// (no `version`, no `mappings`), drops it, and then attaches its fallback: a hires identity map
// with the whole module inlined as base64. Every JSON import ships about 6x its size. The agent
// pane's generated/strings.json (5.3 MB on disk) is served as 26.7 MB; the 19 JSON modules on the
// pane's dev page are 35.8 MB of its 140 MB; settings' strings.json is 28.5 MB. Unwrapping
// `inner` gives the chain the `{ mappings: "" }` it means, so no map is sent and the module code
// stays exactly the same (cmuxterm-hq docs/findings/2026-11-24-dev-json-sourcemaps.md).
//
// Builds are not affected (apply: "serve"). Once the native plugin returns a real map shape, the
// check below matches nothing and this does nothing.
export function jsonDevSourceMap() {
  return {
    name: "cmux-json-dev-source-map",
    apply: "serve",
    configResolved(config) {
      const json = config.plugins.find((plugin) => plugin.name === "builtin:vite-json");
      const hook = json?.transform;
      if (!hook) return;
      const handler = typeof hook === "function" ? hook : hook.handler;
      const unwrapped = async function (...args) {
        const result = await handler.apply(this, args);
        const map = result && typeof result === "object" ? result.map : null;
        if (map && typeof map === "object" && !("version" in map) && map.inner) return { ...result, map: map.inner };
        return result;
      };
      if (typeof hook === "function") json.transform = unwrapped;
      else hook.handler = unwrapped;
    },
  };
}
