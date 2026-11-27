// The launch's first New Tab names the app's last pick until acpmux lists its harnesses (Lucas
// 2026-10-24: the harness chip popped in late). An empty list acpmux answered is a listing too:
// with every harness removed, the page must stop naming the remembered one, so the Add harness
// chip shows and Return never starts a harness that is gone.
import { expect, test } from "bun:test";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import { newTabStart } from "../src/agent-session/acpmux/newtab/chipDefaults";

const snapshot = {
  type: "snapshot",
  protocolVersion: 1,
  rows: [],
  sessions: [],
  connection: "test",
  isWorking: false,
  queue: [],
  canLoadOlder: false,
  catalog: [],
} as unknown as AcpmuxSnapshot;
const remembered = { harness: "claude", model: "claude-opus-5-5" } as never;

test("before acpmux lists its harnesses, the remembered pick stands", () => {
  expect(newTabStart(snapshot, [], undefined, undefined, remembered, false).harness).toBe("claude");
});

test("an empty list acpmux answered ends the remembered pick", () => {
  expect(newTabStart(snapshot, [], undefined, undefined, remembered, true).harness).toBeUndefined();
});
