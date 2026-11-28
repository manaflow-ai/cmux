import { describe, expect, it } from "bun:test";
import fs from "node:fs";
import { createRequire } from "node:module";
import path from "node:path";
import { formatHotSwap, hotSwapStages, refreshRuntimeWithoutTimer } from "../dev-server/hotSwapTiming";
import { refreshInMicrotask } from "../dev-server/refreshNow";

// The runtime @vitejs/plugin-react serves at /@react-refresh, as installed.
const runtime = fs.readFileSync(
  path.join(path.dirname(createRequire(import.meta.url).resolve("@vitejs/plugin-react")), "refresh-runtime.js"),
  "utf8",
);

describe("dev server hot swap timing", () => {
  it("preserves the preceding refreshNow microtask and reports its commit", () => {
    const preceding = refreshInMicrotask(runtime);
    expect(preceding.changed).toBe(true);
    const patched = refreshRuntimeWithoutTimer(preceding.code);
    expect(patched).toBeDefined();
    expect(patched).toContain("queueMicrotask(() =>");
    expect(patched).not.toContain("new MessageChannel()");
    expect(patched).toContain('window.dispatchEvent(new Event("cmux:react-refreshed"))');
  });

  it("takes the 16 ms timer out of the installed React Fast Refresh runtime", () => {
    // A runtime that no longer reads as expected is served as it is (the plugin warns): this
    // fails first when @vitejs/plugin-react changes its debounce.
    const patched = refreshRuntimeWithoutTimer(runtime);
    expect(patched).toBeDefined();
    expect(patched).not.toContain("setTimeout(fn, delay)");
    expect(patched).toContain("new MessageChannel()");
    expect(patched).toContain('window.dispatchEvent(new Event("cmux:react-refreshed"))');
    expect(patched).not.toMatch(/performReactRefresh\(\)\n\}, 16\)/);
  });

  it("serves a runtime it does not recognize unchanged", () => {
    expect(refreshRuntimeWithoutTimer("export const x = 1")).toBeUndefined();
  });

  it("splits a save into its stages on one clock", () => {
    const stages = hotSwapStages(
      { file: "/w/src/ComposerFoot.tsx", mtime: 1000, watch: 1009, sent: 1010 },
      { received: 1010.4, applied: 1020, refreshed: 1021, painted: 1038 },
    );
    expect(stages).toEqual({
      total: 38,
      committed: 21,
      watch: 9,
      server: 1,
      socket: 0,
      module: 10,
      refresh: 1,
      frame: 17,
    });
    expect(formatHotSwap("/w/src/ComposerFoot.tsx", stages)).toBe(
      "[cmux hot swap] ComposerFoot.tsx 38 ms: watch 9, server 1, socket 0, module 10, refresh 1, frame 17",
    );
  });

  it("reports a page that drew no frame up to its commit", () => {
    const stages = hotSwapStages({ file: "/w/a.css", mtime: 0, watch: 5, sent: 6 }, { received: 6, applied: 12 });
    expect(stages.total).toBeUndefined();
    expect(stages.refresh).toBeUndefined();
    expect(formatHotSwap("/w/a.css", stages)).toBe(
      "[cmux hot swap] a.css committed in 12 ms, no frame drawn in 2000 ms: watch 5, server 1, socket 0, module 6",
    );
  });
});
