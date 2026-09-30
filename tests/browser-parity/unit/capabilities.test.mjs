// capabilities.json must map every reference capability to a cmux equivalent
// with differential cases (tests/browser-parity/diff), or to an exclusion the
// design doc lists.
//
//   node --test tests/browser-parity/unit/
import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const caps = JSON.parse(fs.readFileSync(path.join(root, "capabilities.json"), "utf8"));

// Globals and snapshot options from `aside guide repl` (Aside CLI 1.26).
const ASIDE_GLOBALS = ["page", "tabs", "listBrowserTabs", "attachBrowserTab", "attachActiveBrowserTab", "getTabByTargetId",
  "openTab", "closeTab", "snapshot", "snapshot.interactive", "snapshot.showHidden", "snapshot.ref", "snapshot.selector",
  "snapshot.diff", "annotatedScreenshot", "fetch", "fs", "path", "Buffer", "sleep", "display", "pwd", "console"];
// docs/browser-repl/README.md, "Excluded from the references".
// Only raw CDP: WebKit has no DevTools protocol.
const ALLOWED_EXCLUSIONS = new Set(["Browser.capabilities"]);

function asideMembers() {
  const sections = { PAGE: "Page", LOC: "Locator", KB: "Keyboard", MOUSE: "Mouse" };
  const out = [];
  for (const line of fs.readFileSync(path.join(root, "reference/aside-api-surface.txt"), "utf8").split("\n")) {
    const [tag, ...tokens] = line.trim().split(/\s+/);
    if (!sections[tag]) continue;
    // "!name" marks a Playwright member Aside does not have.
    for (const t of tokens) if (!t.startsWith("!")) out.push([sections[tag], t]);
  }
  return out;
}

function chatgptMembers() {
  const seen = new Map();
  return fs.readFileSync(path.join(root, "reference/chatgpt-api-surface.txt"), "utf8").split("\n").filter(Boolean).map((line) => {
    const member = line.split("\t")[0];
    const n = (seen.get(member) || 0) + 1;
    seen.set(member, n);
    return n > 1 ? `${member}#${n}` : member;
  });
}

function checkEntry(name, entry) {
  assert.ok(entry, `${name} is not mapped in capabilities.json`);
  if (entry.excluded !== undefined) {
    assert.ok(ALLOWED_EXCLUSIONS.has(name), `${name} is excluded, but the design doc does not list it as excluded`);
    assert.ok(entry.excluded.length > 20, `${name} needs an exclusion reason`);
    return;
  }
  assert.ok(entry.cmux, `${name} has no cmux equivalent`);
  // unit/diff.test.mjs checks the cases and their verdicts.
  assert.ok(Array.isArray(entry.cases) && entry.cases.length, `${name} needs differential cases`);
  assert.equal(entry.proof, undefined, `${name}: proof keys were replaced by cases`);
}

test("every Aside global maps to cmux", () => {
  for (const g of ASIDE_GLOBALS) checkEntry(`aside ${g}`, caps.aside.globals[g]);
  assert.deepEqual(Object.keys(caps.aside.globals).sort(), [...ASIDE_GLOBALS].sort());
});

test("every Page, Locator, Keyboard and Mouse member Aside has maps to cmux", () => {
  const members = asideMembers();
  assert.ok(members.length > 80, `only ${members.length} Aside members parsed`);
  for (const [cls, name] of members) checkEntry(`aside ${cls}.${name}`, caps.aside[cls][name]);
  for (const cls of ["Page", "Locator", "Keyboard", "Mouse"]) {
    for (const name of Object.keys(caps.aside[cls])) {
      assert.ok(members.some(([c, n]) => c === cls && n === name), `aside ${cls}.${name} is not in the reference surface`);
    }
  }
});

test("every line of the ChatGPT surface maps to cmux or an allowed exclusion", () => {
  const members = chatgptMembers();
  assert.equal(members.length, 152);
  for (const m of members) checkEntry(m, caps.chatgpt[m]);
  assert.deepEqual(Object.keys(caps.chatgpt).sort(), [...members].sort());
});

// Site integrations (docs/browser-repl/site-tools.md): every member in
// reference/site-surface.txt maps to a cmux tool with tests that exist, or to
// a pending user decision.
const SITE_DECISIONS = new Set(["captcha", "password-managers", "imessage", "imagegen", "bot-evasion", "doc-editing", "social-writes", "contacts", "agent-platform"]);

test("every site member maps to a tested cmux tool or a pending decision", async () => {
  const lines = fs.readFileSync(path.join(root, "reference/site-surface.txt"), "utf8").split("\n").filter((l) => l && !l.startsWith("#"));
  assert.ok(lines.length > 100, `only ${lines.length} site members`);
  const sites = caps.sites;
  assert.ok(sites, "capabilities.json has no sites section");
  const { loadCases } = await import("../diff/lib.mjs");
  const caseIds = new Set((await loadCases()).map((c) => c.id));
  const titles = new Map();
  const titlesOf = (file) => {
    if (!titles.has(file)) {
      const text = fs.readFileSync(path.join(root, "sites", file), "utf8");
      titles.set(file, [...text.matchAll(/^test\("((?:[^"\\]|\\.)*)"/gm)].map((m) => m[1]));
    }
    return titles.get(file);
  };
  const seen = { aside: new Set(), chatgpt: new Set() };
  for (const line of lines) {
    const [ref, member] = line.split("\t");
    seen[ref].add(member);
    const entry = sites[ref] && sites[ref][member];
    assert.ok(entry, `site member ${ref} ${member} is not mapped in capabilities.json`);
    if (entry.decision !== undefined) {
      assert.ok(SITE_DECISIONS.has(entry.decision), `${ref} ${member}: unknown decision ${entry.decision}`);
      assert.ok((entry.reason || "").length > 40, `${ref} ${member}: decision needs its reason`);
      continue;
    }
    assert.ok(entry.cmux, `${ref} ${member} has no cmux equivalent`);
    assert.ok(Array.isArray(entry.tests) && entry.tests.length, `${ref} ${member} has no proving test`);
    for (const t of entry.tests) {
      if (t.startsWith("diff:")) {
        assert.ok(caseIds.has(t.slice(5)), `${ref} ${member}: differential case ${t} does not exist`);
        continue;
      }
      const m = /^sites\/([\w.-]+\.test\.mjs): (.+)$/.exec(t);
      assert.ok(m, `${ref} ${member}: test id "${t}" is not sites/<file>: <title> or diff:<case>`);
      const matching = titlesOf(m[1]).filter((title) => title.startsWith(m[2]));
      assert.equal(matching.length, 1, `${ref} ${member}: "${t}" names ${matching.length} tests`);
    }
  }
  for (const ref of ["aside", "chatgpt"]) {
    for (const member of Object.keys(sites[ref])) assert.ok(seen[ref].has(member), `sites ${ref} ${member} is not in reference/site-surface.txt`);
  }
});
