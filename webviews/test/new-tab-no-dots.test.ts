// New Tab always lands on the page and opens a terminal only when one is picked (Leo 2026-10-12):
// the page reads no template dots and no "default: X" toggle from the host, even from a host
// that still sends them, so neither the Terminal dot nor the toggle can make Cmd-T skip the page.
import { expect, test } from "bun:test";
import { newTabHost } from "../src/agent-session/acpmux/NewTabPage";

test("the New Tab page takes no template dots or default-kind toggle from the host", () => {
  const host = newTabHost({
    newTab: { layout: "a", kind: "agent", templateSwitcher: true, defaultKind: "terminal" },
  })! as Record<string, unknown>;
  expect(host).toBeDefined();
  expect(host.templateSwitcher).toBeUndefined();
  expect(host.defaultKind).toBeUndefined();
});
