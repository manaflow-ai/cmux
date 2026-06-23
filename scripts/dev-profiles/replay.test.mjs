// Unit tests for the dev-profile replay engine.
//
// Covers the pure construction half (parse + substitute + resolve + JSON-path
// capture) with no live socket, plus a smoke test that every shipped profile
// file parses and resolves. Run with:
//
//   node --test scripts/dev-profiles/replay.test.mjs

import assert from "node:assert/strict";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { test } from "node:test";

import {
  listProfiles,
  loadProfile,
  readJSONPath,
  resolveSteps,
  substituteArg,
  validateProfile,
} from "./replay.mjs";

const PROFILES_DIR = path.dirname(fileURLToPath(import.meta.url));

test("substituteArg replaces a known variable", () => {
  assert.equal(substituteArg("${cwd}/x", { cwd: "/repo" }), "/repo/x");
});

test("substituteArg replaces multiple variables in one arg", () => {
  assert.equal(
    substituteArg("${a}-${b}", { a: "1", b: "2" }),
    "1-2",
  );
});

test("substituteArg leaves a plain arg untouched", () => {
  assert.equal(substituteArg("workspace", {}), "workspace");
});

test("substituteArg throws on an undefined variable", () => {
  assert.throws(() => substituteArg("${missing}", {}), /undefined variable.*missing/);
});

test("readJSONPath reads a nested dotted path", () => {
  assert.equal(readJSONPath({ group: { id: "G1" } }, "group.id"), "G1");
});

test("readJSONPath returns undefined for a missing path", () => {
  assert.equal(readJSONPath({ a: 1 }, "a.b.c"), undefined);
});

test("validateProfile rejects a profile with no steps", () => {
  assert.throws(() => validateProfile({ steps: [] }), /non-empty array/);
});

test("validateProfile rejects a step with empty args", () => {
  assert.throws(() => validateProfile({ steps: [{ args: [] }] }), /non-empty "args"/);
});

test("validateProfile rejects capture without --json", () => {
  assert.throws(
    () =>
      validateProfile({
        steps: [{ args: ["workspace", "create"], capture: { ws: "workspace_id" } }],
      }),
    /omit "--json"/,
  );
});

test("resolveSteps substitutes context variables into arg vectors", () => {
  const profile = {
    steps: [
      {
        args: ["workspace", "create", "--cwd", "${cwd}", "--json"],
        capture: { ws: "workspace_id" },
      },
    ],
  };
  const resolved = resolveSteps(profile, { cwd: "/home/dev/repo" });
  assert.deepEqual(resolved[0].argv, [
    "workspace",
    "create",
    "--cwd",
    "/home/dev/repo",
    "--json",
  ]);
  assert.deepEqual(resolved[0].capture, { ws: "workspace_id" });
});

test("resolveSteps threads a captured variable into a later step (dry-run token)", () => {
  const profile = {
    steps: [
      { args: ["workspace", "create", "--json"], capture: { ws: "workspace_id" } },
      { args: ["send", "--workspace", "${ws}", "echo hi\\n"] },
    ],
  };
  const resolved = resolveSteps(profile, {});
  // The capture is unknown at construction time, so it resolves to a visible
  // placeholder token rather than throwing.
  assert.deepEqual(resolved[1].argv, [
    "send",
    "--workspace",
    "<captured:ws>",
    "echo hi\\n",
  ]);
});

test("resolveSteps substitutes an explicitly-provided capture value", () => {
  const profile = {
    steps: [
      { args: ["workspace", "create", "--json"], capture: { ws: "workspace_id" } },
      { args: ["send", "--workspace", "${ws}", "x"] },
    ],
  };
  const resolved = resolveSteps(profile, { ws: "workspace:7" });
  assert.deepEqual(resolved[1].argv, ["send", "--workspace", "workspace:7", "x"]);
});

test("every shipped profile parses and resolves", () => {
  const names = listProfiles(PROFILES_DIR);
  assert.ok(names.length >= 5, `expected >=5 profiles, found ${names.join(",")}`);
  for (const name of names) {
    const profile = loadProfile(PROFILES_DIR, name);
    const resolved = resolveSteps(profile, { cwd: "/tmp/repo" });
    assert.ok(resolved.length >= 1, `${name} resolved to zero steps`);
    for (const { argv } of resolved) {
      assert.ok(
        argv.every((a) => !a.includes("${")),
        `${name} left an unresolved placeholder: ${argv.join(" ")}`,
      );
    }
  }
});

test("loadProfile lists alternatives for an unknown name", () => {
  assert.throws(
    () => loadProfile(PROFILES_DIR, "does-not-exist"),
    /unknown profile.*Available:.*composer/,
  );
});

test("the composer profile starts an agent in a captured workspace", () => {
  const profile = loadProfile(PROFILES_DIR, "composer");
  const resolved = resolveSteps(profile, { cwd: "/repo" });
  const first = resolved[0];
  assert.ok(first.argv.includes("--command"));
  assert.ok(first.argv.includes("claude"));
  assert.deepEqual(first.capture, { ws: "workspace_id" });
});
