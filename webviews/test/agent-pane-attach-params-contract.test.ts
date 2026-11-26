// Every `_acpmux/attach` the page sends, as `schemas/agent-pane/attach-params.json` lists them. The
// app's relay checks each frame against its params rule (AcpmuxPaneMethods+Params.swift
// `knownParams`), and `AcpmuxPaneAttachParamsContractTests` runs this same file through that rule.
// A key the page adds here and the relay does not know is refused as `transport.intent_invalid`:
// `settled` once (#42185), then the row store's `hold`, after which no chat typed on the New Tab
// page started (#42460: "Couldn't start Claude Code (sr2 internal): Something went wrong").
import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { forwardAttachRefused, plainAttach } from "../src/agent-session/acpmux/attachParams";
import { holdAttach } from "../src/agent-session/acpmux/rows/holdKinds";

type Contract = { attach: { name: string; params: Record<string, unknown> }[] };
const contract: Contract = JSON.parse(
  readFileSync(join(import.meta.dir, "../../schemas/agent-pane/attach-params.json"), "utf8"),
);
const listed = (name: string) => contract.attach.find((frame) => frame.name === name)?.params;

// The page's attaches by the name the contract gives them (direct.ts `sendAttach`).
// Typed params are interfaces, so they need no index signature here (`object`, not `Record`).
const sent: Record<string, object | undefined> = {
  "plain, local": plainAttach("s", {
    settled: false,
    visible: true,
    attending: true,
    local: true,
    maxBytes: 128 * 1024,
  }),
  "plain, peer": plainAttach("s", {
    settled: false,
    visible: false,
    attending: true,
    local: false,
    maxBytes: 128 * 1024,
  }),
  "settled, local": plainAttach("s", {
    settled: true,
    visible: true,
    attending: true,
    local: true,
    maxBytes: 128 * 1024,
  }),
  // A reconnect that holds the chat's rows (direct.ts `ForwardAttach`, #47119): the relay refused its
  // `afterSeq`, and every such reconnect said "cmux blocked opening this chat" over the composer (Leo,
  // 2026-11-22). A forward attach asks no settled view.
  "forward, local": plainAttach("s", {
    settled: true,
    visible: true,
    attending: true,
    local: true,
    maxBytes: 128 * 1024,
    afterSeq: 120,
  }),
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

  // A host whose params rule predates `afterSeq` refuses the reconnect's attach as malformed: the pane asks
  // the newest page instead (direct.ts sendAttach), never "cmux blocked opening this chat".
  test("a forward attach a host refuses is asked again for the newest page", () => {
    expect(forwardAttachRefused({ code: "transport.intent_invalid", message: 'unknown param "afterSeq"' })).toBe(true);
    expect(forwardAttachRefused(new Error('unknown param "afterSeq"'))).toBe(true);
    expect(forwardAttachRefused({ code: "transport.denied" })).toBe(false);
    expect(forwardAttachRefused(new Error("peer_unreachable: mac"))).toBe(false);
  });
});
