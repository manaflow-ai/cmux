import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";

// Every acpmux method the agent pane asks for by name (`this.request("…")` in direct.ts) must be
// one the app's relay lets through (AcpmuxPaneMethods.requests, with a knownParams entry). The relay
// is default deny: a method left off is refused in the app before acpmux ever sees it, and the page
// says only "The app refused this request." That is how the composer's held-messages panel failed in
// Leo's NIGHTLY ("uhhhh help!", 2026-11-25: "Couldn't read the held messages"): the daemon's gate had
// been fixed (inbox_gate_tests.rs), but `_acpmux/inbox_threads` was never on the app's list. The
// overload warning's `_acpmux/host_overload` was refused the same way.
const repo = path.resolve(import.meta.dir, "../..");
const read = (file: string) => readFileSync(path.join(repo, file), "utf8");
const swift = (file: string) => read(path.join("Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane", file));
const literals = (text: string) => [...text.matchAll(/"([^"\\]+)"/g)].map((match) => match[1]!);

function swiftBlock(text: string, head: string): string {
  const start = text.indexOf(head);
  expect(start).toBeGreaterThan(-1);
  return text.slice(start, text.indexOf("\n    ]", start)).replace(/\/\/.*$/gm, "");
}

// Sent by name in direct.ts but never through the app's relay.
const NOT_RELAYED: Record<string, string> = {
  // The connection's first frame: its own rule (AcpmuxPaneMethods.initialize).
  initialize: "the first frame, checked on its own",
  // Mock mode only (an in-page daemon); in the app the host bridge serves it.
  "file.search": "mock mode only",
  // An enrolled browser's sidebar (refreshBrowserWorkspaces returns early without a browser device).
  "_acpmux/browser_workspaces": "a browser device's own connection, never the app's pane",
};

test("every method the pane requests by name is on the app relay's list, with its params", () => {
  const direct = read("webviews/src/agent-session/acpmux/direct.ts");
  const sent = [...new Set([...direct.matchAll(/this\.request\(\s*"([^"]+)"/g)].map((match) => match[1]!))];
  // The scan still finds the pane's requests (a rename of `this.request` would pass every check).
  expect(sent.length).toBeGreaterThan(50);
  const allowed = new Set(literals(swiftBlock(swift("AcpmuxPaneMethods.swift"), "static let requests: Set<String> = [")));
  const params = swiftBlock(swift("AcpmuxPaneMethods+Params.swift"), "static let knownParams:");
  const withParams = new Set([...params.matchAll(/^\s*"([^"]+)": \(/gm)].map((match) => match[1]!));
  const relayed = sent.filter((method) => !(method in NOT_RELAYED));
  expect(relayed.filter((method) => !allowed.has(method))).toEqual([]);
  expect(relayed.filter((method) => !withParams.has(method))).toEqual([]);
  // An exemption the pane no longer sends is dropped from the list above.
  expect(Object.keys(NOT_RELAYED).filter((method) => !sent.includes(method))).toEqual([]);
});
