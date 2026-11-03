// A chat's name in lists (sessionList.ts sessionTitle): a name that reads as an id or a counter
// (`cloud-item-14`, `optchat-sub-6b68ac4a-a26`) yields to the chat's title (Leo 2026-11-02:
// "that's the agents naming them like that").
import { expect, test } from "bun:test";
import { isOpaqueName, sessionTitle } from "./sessionList";

test("names that read as ids or counters are opaque, task names are not", () => {
  for (const name of ["cloud-item-14", "optchat-sub-6b68ac4a-a26", "optchat-chief-h0me", "dispatch-019a3f2e"])
    expect(isOpaqueName(name)).toBe(true);
  for (const name of ["session-info-drag-handles", "drain-cx-b-cloud-ios", "fix-27310-crash", "tests", "claude-sr2"])
    expect(isOpaqueName(name)).toBe(false);
});

test("an opaque name yields to the chat's title, and still beats New chat without one", () => {
  const t = (key: string) => key;
  const titled = { sessionId: "a", name: "cloud-item-14", harness: "codex", title: "Cloud attach retries" };
  expect(sessionTitle(titled, t)).toBe("Cloud attach retries");
  const peer = { ...titled, name: "gcp-codex-lane-12/optchat-sub-6b68ac4a-a26" };
  expect(sessionTitle(peer, t)).toBe("Cloud attach retries");
  expect(sessionTitle({ sessionId: "b", name: "cloud-item-14", harness: "codex" }, t)).toBe("cloud-item-14");
  // A readable name the launcher gave still wins over the title.
  expect(sessionTitle({ ...titled, name: "session-info-drag-handles" }, t)).toBe("session-info-drag-handles");
  // The harness's own default names are unchanged: the title reads.
  expect(sessionTitle({ ...titled, name: "codex-3" }, t)).toBe("Cloud attach retries");
});
