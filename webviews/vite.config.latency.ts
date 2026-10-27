// Production build of the latency harness pages (test/latency/*.html) for scripts/latency/run.ts:
// the shipped build settings (React Compiler, production React, the same chunking and the diff
// worker), with the harness pages as the HTML inputs. `CMUX_LATENCY_OUT_DIR` names the output.
import base from "./vite.config";
import { SHARED_REACT_PLUGIN } from "./scripts/shared/shared-react.mjs";

const outDir = process.env.CMUX_LATENCY_OUT_DIR ?? "/tmp/cmux-latency-harness";
// The page host's relative-entry rewrite is for the shipped root-level pages only, and the harness
// pages run on a plain server, so they bundle React instead of importing cmux-page://cmux.shared/.
const shippedOnly = new Set(["cmux-diff-page-relative-entry", SHARED_REACT_PLUGIN]);
const plugins = (base.plugins ?? [])
  .flat()
  .filter((plugin) => !(plugin && typeof plugin === "object" && "name" in plugin && shippedOnly.has(plugin.name)));

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
        "latency-settings": "test/latency/settings.html",
      },
    },
  },
};
