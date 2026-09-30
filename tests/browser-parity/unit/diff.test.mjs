// Parity evidence: the differential cases (tests/browser-parity/diff) must
// cover every reference member and every cataloged edge case, and the
// verdicts recomputed from the recorded results must hold no cmux-worse.
//
//   node --test tests/browser-parity/unit/
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { loadCases, readResults, allVerdicts, REFERENCES } from "../diff/lib.mjs";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const repo = path.resolve(root, "../..");
const caps = JSON.parse(fs.readFileSync(path.join(root, "capabilities.json"), "utf8"));
const cases = await loadCases();
const results = Object.fromEntries(["cmux", "cmux-dev", ...REFERENCES].map((b) => [b, readResults(b)]));
const rows = allVerdicts(cases, results);
const byId = new Map(rows.map((r) => [r.id, r]));

function capabilityEntries() {
  const out = [];
  for (const [group, members] of Object.entries(caps.aside)) {
    for (const [name, entry] of Object.entries(members)) out.push({ ref: "aside", member: group === "globals" ? name : `${group}.${name}`, entry });
  }
  for (const [name, entry] of Object.entries(caps.chatgpt)) out.push({ ref: "chatgpt", member: name, entry });
  return out;
}

test("every mapped member lists differential cases that name it", () => {
  const known = new Set(cases.map((c) => c.id));
  for (const { ref, member, entry } of capabilityEntries()) {
    if (entry.excluded !== undefined) continue;
    assert.ok(Array.isArray(entry.cases) && entry.cases.length, `${ref} ${member} has no differential cases`);
    for (const id of entry.cases) {
      assert.ok(known.has(id), `${ref} ${member}: case ${id} does not exist`);
      const c = cases.find((x) => x.id === id);
      assert.ok((c.members ?? []).includes(`${ref}:${member}`), `${ref} ${member}: case ${id} does not list it in members`);
    }
  }
});

test("every case member is a reference member", () => {
  const names = new Set(capabilityEntries().map(({ ref, member }) => `${ref}:${member}`));
  for (const c of cases) for (const m of c.members ?? []) assert.ok(names.has(m), `${c.id}: unknown member ${m}`);
});

test("every mapped member is same or better than its reference in at least one case", () => {
  for (const { ref, member, entry } of capabilityEntries()) {
    if (entry.excluded !== undefined) continue;
    const verdicts = entry.cases.map((id) => byId.get(id)?.refs[ref]?.verdict);
    assert.ok(verdicts.some((v) => v === "same" || v === "cmux-better"), `${ref} ${member}: verdicts ${verdicts.join(", ")}`);
  }
});

// Cases that need a person to act during the run; without a recorded result
// they are reported as unverified (docs/browser-repl/parity-report.md).
const personOnly = new Set(cases.filter((c) => c.requiresPerson).map((c) => c.id));

test("no case is cmux-worse and cmux meets every expectation", () => {
  const worse = [];
  for (const row of rows) {
    if (personOnly.has(row.id) && row.cmuxProblems.join() === "not run") continue;
    if (row.cmuxProblems.length) worse.push(`${row.id}: ${row.cmuxProblems.join("; ")}`);
    for (const ref of REFERENCES) if (row.refs[ref].verdict === "cmux-worse") worse.push(`${row.id} vs ${ref}: ${row.refs[ref].reason}`);
  }
  assert.deepEqual(worse, []);
});

test("every case with reference code has a recorded reference result", () => {
  const missing = [];
  for (const row of rows) for (const ref of REFERENCES) if (row.refs[ref].verdict === "not-run") missing.push(`${row.id} ${ref}: ${row.refs[ref].reason}`);
  assert.deepEqual(missing, []);
});

test("every cataloged edge case has a case, and every case edge is cataloged", () => {
  const doc = fs.readFileSync(path.join(repo, "docs/browser-repl/edge-cases.md"), "utf8");
  const catalog = new Set([...doc.matchAll(/^\| `([a-z0-9-]+)` \|/gm)].map((m) => m[1]));
  assert.ok(catalog.size >= 55, `only ${catalog.size} edge ids in edge-cases.md`);
  const covered = new Set(cases.flatMap((c) => [].concat(c.edge ?? [])));
  for (const id of catalog) assert.ok(covered.has(id), `edge ${id} has no case`);
  for (const id of covered) assert.ok(catalog.has(id), `case edge ${id} is not in edge-cases.md`);
});

test("exclusions are only what WebKit cannot do", () => {
  const excluded = capabilityEntries().filter(({ entry }) => entry.excluded !== undefined).map(({ ref, member }) => `${ref}:${member}`);
  assert.deepEqual(excluded.sort(), ["chatgpt:Browser.capabilities"]);
});
