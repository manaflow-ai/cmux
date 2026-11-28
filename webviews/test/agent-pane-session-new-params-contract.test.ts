// Every `session/new` the page sends, as `schemas/agent-pane/session-new-params.json` lists them. The
// app's relay checks each frame against its params rule (AcpmuxPaneMethods+Params.swift
// `knownParams`), and `AcpmuxPaneSessionNewParamsContractTests` runs this same file through that
// rule. A key the page adds to a start that the relay does not know is refused as
// `transport.intent_invalid`, and then no chat starts, for any agent: the attach's `settled` and
// `hold` keys did that to every chat open (#42185, #42460; the 2026-11-12 outage, #44964).
import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { type AcpmuxAdopt, newSessionParams } from "../src/agent-session/acpmux/direct";

type Contract = { new: { name: string; params: Record<string, unknown> }[] };
const contract: Contract = JSON.parse(
  readFileSync(join(import.meta.dir, "../../schemas/agent-pane/session-new-params.json"), "utf8"),
);
const listed = (name: string) => contract.new.find((frame) => frame.name === name)?.params;

const adopt = { harness: "claude", sessionId: "native-1", cwd: "/work/project" } as unknown as AcpmuxAdopt;
// The page's starts by the name the contract gives them (direct.ts `startSession`, `adoptSession`).
const sent: Record<string, Record<string, unknown>> = {
  "local, folder": newSessionParams({ cwd: "/work/project" }, "claude"),
  "local, folder and extra folders": newSessionParams({ cwd: "/work/project" }, "claude", false, undefined, [
    "/work/shared",
  ]),
  "local, folder, read-only": newSessionParams({ cwd: "/work/project" }, "claude", false, undefined, undefined, true),
  "local, folder, Auto place": newSessionParams(
    { cwd: "/work/project" },
    "claude",
    false,
    undefined,
    undefined,
    false,
    undefined,
    true,
  ),
  "no project": newSessionParams({}, "claude", true),
  "peer, model": newSessionParams({ peer: "devbox" }, "codex", false, "gpt-5.5"),
  "Cloud peer, registry": newSessionParams(
    { peer: "cloud-builder" },
    "claude",
    false,
    undefined,
    undefined,
    false,
    "registry-builder",
  ),
  adopt: newSessionParams({ adopt }),
};

// The params rule's view of a start: its top-level keys, and the keys of `_meta.acpmux`.
const acpmuxKeys = (params: Record<string, unknown>) =>
  Object.keys(((params._meta as { acpmux?: Record<string, unknown> } | undefined)?.acpmux ?? {}) as object);

describe("the page's session/new params are the contract's", () => {
  for (const [name, params] of Object.entries(sent)) {
    test(name, () => {
      // Through JSON, as the frame goes: an unset harness is no key.
      expect(listed(name)).toEqual(JSON.parse(JSON.stringify(params)));
    });
  }

  // The host's pane policy as data (cmux-agent-pane-policy policy.json, which its tests/swift.rs keeps
  // equal to AcpmuxPaneMethods knownParams): the params rule takes every key of every start.
  test("the pane policy's params rule takes every start", () => {
    const policy = JSON.parse(
      readFileSync(join(import.meta.dir, "../../cmux-tui/crates/cmux-agent-pane-policy/policy.json"), "utf8"),
    ) as { known_params: Record<string, { params: string[]; acpmux: string[] }> };
    const known = policy.known_params["session/new"]!;
    for (const frame of contract.new)
      expect({
        name: frame.name,
        refused: [
          ...Object.keys(frame.params).filter((key) => !known.params.includes(key)),
          ...acpmuxKeys(frame.params).filter((key) => !known.acpmux.includes(key)),
        ],
      }).toEqual({ name: frame.name, refused: [] });
  });

  test("the contract lists no start the page does not send", () => {
    expect(contract.new.map((frame) => frame.name).sort()).toEqual(Object.keys(sent).sort());
  });
});
