// Loading src/ with a document in place, for a test file that installs its own DOM later (in a test,
// in beforeAll, or per test).
//
// Some modules decide once, when they first load, whether they run in a browser: Floating UI's React
// bindings set `isClient = typeof document !== "undefined"`, Base UI checks for a document the same
// way, and react-dom picks its event names. `bun test` keeps one module cache for every file of a
// process, so a file that imports src/ at the top and installs jsdom afterwards loads those modules
// with no document, and every later file of the process gets the browser-less copy: popups that never
// position, layout effects that never run (session-info-motion before
// session-info-subagent-card-stays, #46384). import-order-lint.test.ts fails a file that does that.
//
//   const { SessionInfo } = await importWithDom(() => import("../src/agent-session/acpmux/session-info/SessionInfo"));
//
// installs a throwaway jsdom window as the globals that are missing, runs `load`, and puts the
// globals back as they were, so the file's own DOM install and teardown see what they saw before.
import { JSDOM } from "jsdom";

// What those checks read: a document, and the element classes and registry a web component module
// defines itself with (@pierre/diffs: `typeof HTMLElement !== "undefined" && customElements.get(...)`).
const KEYS = ["window", "document", "navigator", "Node", "Element", "HTMLElement", "customElements"] as const;

export async function importWithDom<T>(load: () => Promise<T>): Promise<T> {
  const scope = globalThis as Record<string, unknown>;
  if ("document" in scope && "window" in scope) return load();
  const { window } = new JSDOM("<!doctype html>", { url: "http://localhost/" });
  const added = KEYS.filter((key) => !(key in scope));
  for (const key of added) scope[key] = key === "window" ? window : (window as unknown as Record<string, unknown>)[key];
  try {
    return await load();
  } finally {
    for (const key of added) delete scope[key];
  }
}
