// capabilities.json must map every reference capability to a cmux equivalent
// proven by a scenario golden, or to an exclusion the design doc lists.
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
const ALLOWED_EXCLUSIONS = new Set(["Browser.capabilities", "Browser.history", "BrowserUser.claimTab", "Tabs.content",
  "ContentAPI.exportGsuite", "ContentAPI.exportYouTubeTranscript"]);

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

const goldenKeys = new Map();
function hasGoldenKey(proof) {
  const at = proof.indexOf(":");
  const scenario = proof.slice(0, at);
  const key = proof.slice(at + 1);
  if (!goldenKeys.has(scenario)) {
    const file = path.join(root, "goldens", `${scenario}.json`);
    const g = fs.existsSync(file) ? JSON.parse(fs.readFileSync(file, "utf8")) : { oracle: {}, cmux: {} };
    goldenKeys.set(scenario, new Set([...Object.keys(g.oracle), ...Object.keys(g.cmux)]));
  }
  return goldenKeys.get(scenario).has(key);
}

function checkEntry(name, entry) {
  assert.ok(entry, `${name} is not mapped in capabilities.json`);
  if (entry.excluded !== undefined) {
    assert.ok(ALLOWED_EXCLUSIONS.has(name), `${name} is excluded, but the design doc does not list it as excluded`);
    assert.ok(entry.excluded.length > 20, `${name} needs an exclusion reason`);
    return;
  }
  assert.ok(entry.cmux, `${name} has no cmux equivalent`);
  assert.match(entry.proof || "", /^\d\d-[\w-]+:.+$/, `${name} needs a proof "<scenario>:<key>"`);
  assert.ok(hasGoldenKey(entry.proof), `${name}: proof ${entry.proof} is not a key in that scenario's golden`);
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
