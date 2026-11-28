// What the agent pane parses before its first paint, read from the pane build's esbuild metafile:
// the entry's output and every chunk it imports statically (directly or through another chunk, the
// set bundle.mjs --preload-list names), their bytes, and the source inputs that fill them.
//
//   bun scripts/agent-pane/startupGraph.mjs METAFILE [--top N] [--json OUT]
//
// METAFILE is the `agent-pane.json` a report build writes (CMUX_BUNDLE_REPORT_DIR=DIR
// scripts/cmux-next/build-agent-pane-web.sh). The entry is the output whose entryPoint is the pane's
// main.tsx. A dynamic import() is lazy and not counted. The table is the before/after number for a
// change that moves code out of the pane's first script (cmuxterm-hq finding
// 2026-11-19-agent-pane-startup-graph).
import { readFileSync, writeFileSync } from "node:fs";

/** The outputs the browser fetches before `entry` runs: `entry` and its static-import closure. */
export function startupOutputs(outputs, entry) {
  const seen = new Set([entry]);
  const queue = [entry];
  while (queue.length) {
    for (const item of outputs[queue.shift()]?.imports ?? []) {
      if (item.kind !== "import-statement" || item.external || seen.has(item.path)) continue;
      seen.add(item.path);
      queue.push(item.path);
    }
  }
  return [...seen];
}

/** The pane's startup set from an esbuild metafile: files, bytes, and the inputs that fill them. */
export function startupGraph(metafile, entrySuffix = "acpmux/main.tsx") {
  const outputs = metafile.outputs ?? {};
  const entry = Object.keys(outputs).find((name) => outputs[name].entryPoint?.endsWith(entrySuffix));
  if (!entry) throw new Error(`no output has an entryPoint ending in ${entrySuffix}`);
  const files = startupOutputs(outputs, entry).filter((name) => !name.endsWith(".map"));
  const inputs = new Map();
  let bytes = 0;
  for (const name of files) {
    bytes += outputs[name].bytes ?? 0;
    for (const [input, info] of Object.entries(outputs[name].inputs ?? {})) {
      inputs.set(input, (inputs.get(input) ?? 0) + (info.bytesInOutput ?? 0));
    }
  }
  const lazyBytes = Object.entries(outputs)
    .filter(([name]) => !name.endsWith(".map") && !files.includes(name))
    .reduce((sum, [, output]) => sum + (output.bytes ?? 0), 0);
  return {
    entry,
    files: files.length,
    bytes,
    entryBytes: outputs[entry].bytes ?? 0,
    lazyBytes,
    inputs: [...inputs].map(([input, inOutput]) => ({ input, bytes: inOutput })).sort((a, b) => b.bytes - a.bytes),
  };
}

if (import.meta.main) {
  const args = process.argv.slice(2);
  const metafilePath = args.find(
    (arg, index) => !arg.startsWith("--") && !["--top", "--json"].includes(args[index - 1]),
  );
  if (!metafilePath) {
    console.error("usage: startupGraph.mjs METAFILE [--top N] [--json OUT]");
    process.exit(2);
  }
  const topIndex = args.indexOf("--top");
  const top = topIndex >= 0 ? Number(args[topIndex + 1]) : 20;
  const jsonIndex = args.indexOf("--json");
  const graph = startupGraph(JSON.parse(readFileSync(metafilePath, "utf8")));
  if (jsonIndex >= 0) writeFileSync(args[jsonIndex + 1], JSON.stringify(graph, null, 2));
  console.log(
    `agent pane startup set: ${graph.files} files, ${graph.bytes} B (entry ${graph.entryBytes} B); lazy chunks ${graph.lazyBytes} B`,
  );
  console.log("| input | bytes in startup set |\n|---|---:|");
  for (const { input, bytes } of graph.inputs.slice(0, top)) console.log(`| \`${input}\` | ${bytes} |`);
}
