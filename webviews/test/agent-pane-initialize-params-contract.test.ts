// The page's `initialize`, as `schemas/agent-pane/initialize-params.json` lists it. The app's relay
// checks it against its params rule (AcpmuxPaneMethods+Params.swift `knownParams`), and
// `AcpmuxPaneInitializeParamsContractTests` runs this same file through that rule. cmux#46563 added
// `_meta.acpmux.peerRowBatches` here and not there: the relay refused every initialize as
// `transport.intent_invalid`, and every chat in the app reconnected every few seconds
// (ask-0e0d5a479b).
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { initializeParams } from "../src/agent-session/acpmux/direct";

const root = join(import.meta.dir, "../..");
const contract = JSON.parse(readFileSync(join(root, "schemas/agent-pane/initialize-params.json"), "utf8")) as {
  initialize: Record<string, unknown>;
};

test("the page's initialize params are the contract's", () => {
  expect(contract.initialize).toEqual(JSON.parse(JSON.stringify(initializeParams())));
});

// The host's pane policy as data (cmux-agent-pane-policy policy.json, which its tests/swift.rs keeps
// equal to AcpmuxPaneMethods.swift): the params rule takes every key of the initialize.
test("the pane policy's params rule takes the initialize", () => {
  const policy = JSON.parse(readFileSync(join(root, "cmux-tui/crates/cmux-agent-pane-policy/policy.json"), "utf8")) as {
    known_params: Record<string, { params: string[]; acpmux: string[] }>;
  };
  const known = policy.known_params.initialize;
  const params = contract.initialize;
  const acpmux = Object.keys((params._meta as { acpmux?: object } | undefined)?.acpmux ?? {});
  expect(Object.keys(params).filter((key) => !known.params.includes(key))).toEqual([]);
  expect(acpmux.filter((key) => !known.acpmux.includes(key))).toEqual([]);
});
