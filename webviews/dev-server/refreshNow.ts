// React Fast Refresh runs in the same task as the hot update instead of 16 ms later.
// @vitejs/plugin-react's runtime (`/@react-refresh`) debounces `performReactRefresh` by 16 ms so
// the modules of one update refresh together. The Vite client already applies one update's
// modules in a single synchronous loop (`queueUpdate` waits for every fetch, then runs each
// module's accept callback in turn), so a microtask after that loop batches the same modules and
// every save shows 16 ms sooner. Two separate updates now refresh twice, which is what they are.
import type { Plugin } from "vite-plus";

const RUNTIME = "/@react-refresh";
// The runtime's line, as plugin-react 6 writes it: `const enqueueUpdate = debounce(async () => {`.
const DEBOUNCED = /const enqueueUpdate = debounce\((async \(\) => \{[\s\S]*?\n\}), 16\)/;

/** The runtime with its 16 ms debounce replaced by one microtask per batch; unchanged if the
 *  runtime no longer has that debounce (a plugin-react upgrade), with the reason. */
export function refreshInMicrotask(code: string): { code: string; changed: boolean } {
  if (!DEBOUNCED.test(code)) return { code, changed: false };
  return {
    changed: true,
    code: code.replace(
      DEBOUNCED,
      (_line, body: string) => `const enqueueUpdate = (() => {
  // cmux (webviews/dev-server/refreshNow.ts): one refresh per update, at the end of its task.
  let queued = false
  const run = ${body}
  return () => {
    if (queued) return
    queued = true
    queueMicrotask(() => {
      queued = false
      void run()
    })
  }
})()`,
    ),
  };
}

export function refreshNow(): Plugin {
  return {
    name: "cmux-refresh-now",
    apply: "serve",
    transform: {
      filter: { id: /^\/@react-refresh$/ },
      handler(code, id) {
        if (id !== RUNTIME) return;
        const result = refreshInMicrotask(code);
        if (!result.changed) {
          this.warn("plugin-react's refresh runtime no longer debounces by 16 ms; dev-server/refreshNow.ts left it");
          return;
        }
        return { code: result.code, map: null };
      },
    },
  };
}
