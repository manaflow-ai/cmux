// Production build of the team board's perf harness (bench/board/harness.html) for
// bench/board/run.ts: the shipped build settings (React Compiler, production React), with the
// harness page as the only input. `CMUX_BOARD_BENCH_OUT_DIR` names the output.
import base from "./vite.config";

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
    outDir: process.env.CMUX_BOARD_BENCH_OUT_DIR ?? "/tmp/cmux-board-bench",
    emptyOutDir: true,
    minify: true,
    rolldownOptions: {
      ...base.build?.rolldownOptions,
      input: { "board-bench": "bench/board/harness.html" },
    },
  },
};
