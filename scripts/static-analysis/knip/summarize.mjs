// Summarize knip JSON reports. argv: <out.txt> <label=report.json>...
// Prints one block per package: counts per issue type, then every unused file and
// dependency (exports and types are counted here; the full lists stay in the JSON).
// Last stdout line: TOTAL <n>.
import { readFileSync, writeFileSync } from "node:fs";

const [outFile, ...reports] = process.argv.slice(2);
const LISTED = ["files", "dependencies", "devDependencies", "optionalPeerDependencies", "unlisted", "binaries", "unresolved"];
let total = 0;
const lines = [];
for (const arg of reports) {
  const eq = arg.indexOf("=");
  const label = arg.slice(0, eq);
  const file = arg.slice(eq + 1);
  let data;
  try {
    data = JSON.parse(readFileSync(file, "utf8"));
  } catch (error) {
    lines.push(`## ${label}: knip produced no JSON (${error.message})`, "");
    continue;
  }
  const counts = {};
  const listed = {};
  for (const issue of data.issues ?? []) {
    for (const [type, value] of Object.entries(issue)) {
      const items = Array.isArray(value) ? value : value && typeof value === "object" ? Object.values(value) : null;
      if (!items || type === "file" || items.length === 0) continue;
      counts[type] = (counts[type] ?? 0) + items.length;
      if (LISTED.includes(type)) {
        for (const item of items) {
          const where = item.line ? `${issue.file}:${item.line}` : issue.file;
          (listed[type] ??= []).push(type === "files" ? issue.file : `${where}: ${item.name}`);
        }
      }
    }
  }
  const n = Object.values(counts).reduce((a, b) => a + b, 0);
  total += n;
  const summary = Object.entries(counts).map(([k, v]) => `${k}=${v}`).join(" ") || "clean";
  lines.push(`## ${label}: ${n} (${summary})`);
  for (const type of LISTED) {
    if (!listed[type]) continue;
    lines.push(`  ${type}:`);
    for (const entry of [...new Set(listed[type])].sort()) lines.push(`    ${entry}`);
  }
  lines.push("");
}
writeFileSync(outFile, `${lines.join("\n")}\n`);
process.stdout.write(`${lines.join("\n")}\nTOTAL ${total}\n`);
