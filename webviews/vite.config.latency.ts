// Production build of the latency harness pages (test/latency/*.html) for scripts/latency/run.ts:
// the shipped build settings (React Compiler, production React, the same chunking and the diff
// worker), with the harness pages as the HTML inputs. `CMUX_LATENCY_OUT_DIR` names the output.
import base from "./vite.config";

const outDir = process.env.CMUX_LATENCY_OUT_DIR ?? "/tmp/cmux-latency-harness";
const plugins = (base.plugins ?? []).flat().filter(
  // The page host's relative-entry rewrite is for the shipped root-level pages only.
  (plugin) =>
    !(plugin && typeof plugin === "object" && "name" in plugin && plugin.name === "cmux-diff-page-relative-entry"),
);

export default {
  ...base,
  plugins,
  build: {
    ...base.build,
    outDir,
    emptyOutDir: true,
    minify: true,
    rolldownOptions: {
      ...base.build?.rolldownOptions,
      input: {
        "diff-worker": "src/diff-worker.ts",
        "latency-diff": "test/latency/diff.html",
        "latency-markdown": "test/latency/markdown.html",
        "latency-picker": "test/latency/picker.html",
        "latency-agent-pane": "test/latency/agent-pane.html",
      },
    },
  },
};
