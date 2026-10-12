import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { acpmuxSocketPath } from "../src/acpmux-client.ts";

// The acpmux socket every host and client resolves, against the shared cases
// (cmux-tui/crates/cmux-agent-pane-policy/tests/cases/environment.json) the Rust
// policy, the Swift host, cmux-tui and the Chief run too: a configured
// ACPMUX_SOCKET past the Unix socket limit and a long home reach the short alias
// the daemon binds.
const cases = JSON.parse(
  readFileSync(
    join(import.meta.dir, "../../../cmux-tui/crates/cmux-agent-pane-policy/tests/cases/environment.json"),
    "utf8",
  ),
) as { sockets: [string, number, string][]; configured_sockets: [string, string, number, string][] };

test("a home's default socket matches the shared cases", () => {
  expect(cases.sockets.length).toBeGreaterThan(0);
  for (const [home, uid, want] of cases.sockets)
    expect(acpmuxSocketPath({ ACPMUX_HOME: home }, uid)).toBe(want);
});

test("a configured ACPMUX_SOCKET matches the shared cases", () => {
  expect(cases.configured_sockets.length).toBeGreaterThan(0);
  for (const [configured, home, uid, want] of cases.configured_sockets)
    expect(acpmuxSocketPath({ ACPMUX_SOCKET: configured, ACPMUX_HOME: home }, uid)).toBe(want);
});
