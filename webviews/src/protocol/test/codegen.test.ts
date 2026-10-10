import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { generate } from "../codegen/generate";

const protocolRoot = path.resolve(import.meta.dir, "..");
const irPath = path.join(protocolRoot, "ir/pane-protocol.json");
const committedIr: unknown = JSON.parse(readFileSync(irPath, "utf8"));

test("committed generated files match a fresh generation (the --check contract)", () => {
  const files = generate(committedIr, { source: "webviews/src/protocol/ir/pane-protocol.json" });
  for (const [name, content] of Object.entries(files)) {
    expect(readFileSync(path.join(protocolRoot, "generated", name), "utf8")).toBe(content);
  }
});
