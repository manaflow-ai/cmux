// l10n-allow-file: a command's report words, never shown in the app.
// The Cloud ergonomics measurement (src/agent-session/acpmux/cloudErgonomics/measure.tsx) as a command, for
// cmuxterm-hq's `cloud-ergonomics-linux` synthetic probe: every Cloud error and wait the agent pane draws,
// rendered in jsdom as App.tsx draws it, each control clicked and read.
//
//   bun scripts/cloud-ergonomics.ts [--out FILE]
//
// Prints one summary line and writes the JSON report to FILE (or stdout). Exits 1 when a state did not render
// (the catalog no longer matches the pane), 0 otherwise: the counts are the result, not a pass or fail.
import { writeFileSync } from "node:fs";

// The test preload's environment: the pane's strings table, Base UI's layout effects, react-dom's events.
await import("../test/preload.ts");
const { measureCloudErgonomics } = await import("../src/agent-session/acpmux/cloudErgonomics/measure");

const at = process.argv.indexOf("--out");
const out = at >= 0 ? process.argv[at + 1] : undefined;
const started = performance.now();
const report = await measureCloudErgonomics();
const json = `${JSON.stringify({ ...report, ms: Math.round(performance.now() - started) }, null, 1)}\n`;
if (out) writeFileSync(out, json);
else process.stdout.write(json);
console.error(
  `cloud ergonomics: ${report.errors_with_next_step}/${report.errors_total} errors say what to do next in the pane ` +
    `(${report.errors_out_of_app} point out of it, ${report.errors_dead_end} dead ends); ` +
    `${report.waits_with_reason_and_eta}/${report.waits_total} waits give a reason and an ETA` +
    (report.missing.length ? `; did not render: ${report.missing.join(", ")}` : ""),
);
process.exit(report.missing.length ? 1 : 0);
