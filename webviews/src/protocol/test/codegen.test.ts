import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { generate } from "../codegen/generate";
import * as validators from "../generated/validators";

const protocolRoot = path.resolve(import.meta.dir, "..");
const irPath = path.join(protocolRoot, "ir/pane-protocol.json");
const committedIr: unknown = JSON.parse(readFileSync(irPath, "utf8"));

test("committed generated files match a fresh generation (the --check contract)", () => {
  const files = generate(committedIr, { source: "webviews/src/protocol/ir/pane-protocol.json" });
  for (const [name, content] of Object.entries(files)) {
    expect(readFileSync(path.join(protocolRoot, "generated", name), "utf8")).toBe(content);
  }
});

test("generated validators accept and ignore fields a newer peer adds", () => {
  // A daemon or provider one version newer may add a field to any message; an older reader keeps
  // working. Wrong types and missing required fields still fail.
  expect(validators.validateEndpoint({ kind: "ws", url: "ws://127.0.0.1:1/", future: true })).toEqual([]);
  expect(validators.validateGitStatusParams({ cwd: "/repo", future: { nested: 1 } })).toEqual([]);
  expect(validators.validateGitStatusParams({ future: true })).not.toEqual([]);
  expect(validators.validateGitStatusParams({ cwd: 5, future: true })).not.toEqual([]);
});
