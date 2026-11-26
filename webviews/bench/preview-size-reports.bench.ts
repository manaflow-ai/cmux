// l10n-allow-file: benchmark output, not shipped UI.
// Height reports an inline preview's frame posts to the pane during a pane-resize drag
// (previewDocument.ts REPORTER). The frame's ResizeObserver watches its document element, so every
// width change fires it; the pane only needs a report when the height moves (the text rewrapped).
// Each report crosses the frame boundary and runs the pane's message handler and a setState.
//
// The frame's script is read from source and run with a stubbed observer, `load` event and
// `parent.postMessage` (no browser: the count is exact, so the 5 runs agree). Scenario: the first
// observation and `load` at the same height, then a 120-frame drag where the width changes every
// frame and the height grows by a line every 20th frame. Prints the post count of each run and p50.
//   bun bench/preview-size-reports.bench.ts [--runs 5]
/// <reference types="bun" />
import path from "node:path";

const runsArg = process.argv.indexOf("--runs");
const runCount = runsArg > 0 ? Number(process.argv[runsArg + 1]) : 5;
const source = await Bun.file(
  path.join(import.meta.dir, "../src/agent-session/acpmux/conversation/previewDocument.ts"),
).text();
const script = source
  .match(/const REPORTER = `([\s\S]*?)`;/)![1]
  .replaceAll("${INLINE_PREVIEW_SIZE}", "cmux-preview-size");

function run(): number {
  let posts = 0;
  let height = 400;
  const observers: Array<() => void> = [];
  const listeners: Record<string, Array<() => void>> = {};
  const scope = {
    parent: { postMessage: () => void posts++ },
    document: {
      documentElement: {
        get scrollHeight() {
          return height;
        },
      },
      getElementById: () => null,
      getElementsByName: () => [],
    },
    ResizeObserver: class {
      constructor(callback: () => void) {
        observers.push(callback);
      }
      observe() {}
    },
    addEventListener: (type: string, callback: () => void) => void (listeners[type] ??= []).push(callback),
    Element: class {},
  };
  new Function(...Object.keys(scope), script)(...Object.values(scope));
  observers.forEach((callback) => callback());
  listeners.load?.forEach((callback) => callback());
  for (let frame = 0; frame < 120; frame++) {
    if (frame % 20 === 0) height += 18;
    observers.forEach((callback) => callback());
  }
  return posts;
}

const posts = Array.from({ length: runCount }, run).sort((a, b) => a - b);
console.log(JSON.stringify({ bench: "preview-size-reports", posts, p50: posts[Math.floor(posts.length / 2)] }));
