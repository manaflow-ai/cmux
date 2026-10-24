// A folder picked for an unsent chat is where a terminal opened from that chat starts: Ctrl-`
// from a New Tab chat on ~/manaflow/cmuxterm-hq opened the terminal at ~ instead (2026-10-20).
import { expect, test } from "bun:test";
import { paneContext } from "../src/agent-session/acpmux/paneContext";

const sessionless = { rows: [], sessions: [], sessionId: undefined };

test("an unsent chat's picked folder is its context cwd", () => {
  expect(paneContext(sessionless, "/Users/me/manaflow/cmuxterm-hq").cwd).toBe("/Users/me/manaflow/cmuxterm-hq");
});

test("no pick and no session leaves the cwd to the host", () => {
  expect(paneContext(sessionless).cwd).toBeUndefined();
});

test("a started chat's session cwd wins over a stale pick", () => {
  const started = { rows: [], sessions: [{ sessionId: "s1", cwd: "/work/session" }], sessionId: "s1" };
  expect(paneContext(started as never, "/work/draft").cwd).toBe("/work/session");
});

test("a New Tab page's project chip wins before a chat starts", () => {
  expect(paneContext(sessionless, { shown: "/work/page", draft: "/work/draft" }).cwd).toBe("/work/page");
});
