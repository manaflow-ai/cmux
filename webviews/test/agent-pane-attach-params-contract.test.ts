// Every `_acpmux/attach` the page sends, as `schemas/agent-pane/attach-params.json` lists them. The
// app's relay checks each frame against its params rule (AcpmuxPaneMethods+Params.swift
// `knownParams`), and `AcpmuxPaneAttachParamsContractTests` runs this same file through that rule.
// A key the page adds here and the relay does not know is refused as `transport.intent_invalid`:
// `settled` once (#42185), then the row store's `hold`, after which no chat typed on the New Tab
// page started (#42460: "Couldn't start Claude Code (sr2 internal): Something went wrong").
import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { plainAttach } from "../src/agent-session/acpmux/attachParams";
import { holdAttach } from "../src/agent-session/acpmux/rows/holdKinds";

type Contract = { attach: { name: string; params: Record<string, unknown> }[] };
const contract: Contract = JSON.parse(
  readFileSync(join(import.meta.dir, "../../schemas/agent-pane/attach-params.json"), "utf8"),
);
const listed = (name: string) => contract.attach.find((frame) => frame.name === name)?.params;

// The page's attaches by the name the contract gives them (direct.ts `sendAttach`).
// Typed params are interfaces, so they need no index signature here (`object`, not `Record`).
const sent: Record<string, object | undefined> = {
  "plain, local": plainAttach("s", { settled: false, visible: true, local: true, maxBytes: 128 * 1024 }),
  "plain, peer": plainAttach("s", { settled: false, visible: false, local: false, maxBytes: 128 * 1024 }),
  "settled, local": plainAttach("s", { settled: true, visible: true, local: true, maxBytes: 128 * 1024 }),
  hold: holdAttach("s", true),
};

describe("the page's _acpmux/attach params are the contract's", () => {
  for (const [name, params] of Object.entries(sent)) {
    test(name, () => {
      expect(params).toBeDefined();
      expect(listed(name)).toEqual(params as Record<string, unknown>);
    });
  }

  // The host's pane policy as data (cmux-agent-pane-policy policy.json, which its tests/swift.rs keeps
  // equal to AcpmuxPaneMethods.swift): the params rule takes every key of every attach.
  test("the pane policy's params rule takes every attach", () => {
    const policy = JSON.parse(
      readFileSync(join(import.meta.dir, "../../cmux-tui/crates/cmux-agent-pane-policy/policy.json"), "utf8"),
    ) as { known_params: Record<string, { params: string[] }> };
    const known = policy.known_params["_acpmux/attach"]?.params ?? [];
    for (const frame of contract.attach)
      expect({ name: frame.name, refused: Object.keys(frame.params).filter((key) => !known.includes(key)) }).toEqual({
        name: frame.name,
        refused: [],
      });
  });

  test("the contract lists no attach the page does not send", () => {
    expect(contract.attach.map((frame) => frame.name).sort()).toEqual(Object.keys(sent).sort());
  });
});
