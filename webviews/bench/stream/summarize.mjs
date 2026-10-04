// Prints a Markdown table of the display metrics for every run JSON in a results folder.
//   node webviews/bench/stream/summarize.mjs DIR
import fs from "node:fs";
import path from "node:path";
import { analyze } from "./analyze.mjs";

const dir = process.argv[2];
const rows = [];
for (const file of fs.readdirSync(dir).sort()) {
  if (!file.endsWith(".json") || file.startsWith("parse-") || file.endsWith("-fixture.json")) continue;
  const a = analyze(JSON.parse(fs.readFileSync(path.join(dir, file), "utf8")));
  const d = a.display;
  rows.push([
    a.harness,
    a.engine,
    a.wire.chunks,
    `${d.framesThatChangedText} (${Math.round(d.shareOfFramesChanged * 100)}%)`,
    `${d.charsPerChangedFrame.p50} / ${d.charsPerChangedFrame.p99}`,
    `${d.frameGapMs.p99} / ${d.frameGapMs.max}`,
    d.over16_7,
    d.longtasks,
    `${d.edgeJumpsOver10px} (max ${d.edgeMovePx.max})`,
    `${d.lastBlockShrinks}`,
    `${d.code.rebuilds} / ${d.code.emptyFrames}`,
    d.scrolledAnchorDriftPx.max,
    a.react ? `${a.react.commits} @ ${a.react.commitMs.p50}/${a.react.commitMs.p99}` : "",
    a.cpu?.TaskDuration !== undefined
      ? `${a.cpu.TaskDuration} (${a.cpu.ScriptDuration}/${a.cpu.LayoutDuration}/${a.cpu.RecalcStyleDuration})`
      : "",
  ]);
}
const head = [
  "run",
  "engine",
  "chunks",
  "frames with new text",
  "chars/changed frame p50/p99",
  "frame gap p99/max ms",
  "frames >20.9ms",
  "long tasks",
  "pinned jumps >10px",
  "last-block shrinks",
  "code rebuilds / empty frames",
  "scrolled-up drift px",
  "React commits @ p50/p99 ms",
  "main thread ms (script/layout/style)",
];
console.log(`| ${head.join(" | ")} |`);
console.log(`|${head.map(() => "---").join("|")}|`);
for (const row of rows) console.log(`| ${row.join(" | ")} |`);
