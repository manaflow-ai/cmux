// The recent chats a New Tab page's context carries (`warm`, newtab/warmSnapshot.ts): what a page
// of this Mac listed last, so the next page's first frame lists them (Leo 2026-10-19: the recent
// chats flickered as a new workspace opened). The page lists them until its own list arrives.
import { afterEach, expect, jest, test } from "bun:test";
import { newTabHost } from "../src/agent-session/acpmux/newTabModel";
import { deviceChats, setDeviceChats } from "../src/agent-session/acpmux/newtab/deviceChats";
import {
  publishWarmNewTab,
  resetWarmNewTabForTests,
  shownNewTabSessions,
  warmNewTabSessions,
} from "../src/agent-session/acpmux/newtab/warmSnapshot";
import { session } from "../src/gallery/fixtures/acpmux";

afterEach(() => {
  jest.useRealTimers();
  resetWarmNewTabForTests();
  setDeviceChats([]);
});

const sessions = [
  session({ sessionId: "older", cwd: "/Users/you/src/billing", updatedAt: 1_000 }),
  session({ sessionId: "newer", cwd: "/Users/you/src/atlas", updatedAt: 2_000 }),
];
const device = [{ key: "codex:d1", harness: "codex", title: "On this Mac", updatedAt: 500 }];

test("every opening's context seeds the page's chats and device chats", () => {
  newTabHost({ newTab: { kind: "agent", warm: JSON.stringify({ sessions, device }) } });
  expect(warmNewTabSessions().map((entry) => entry.sessionId)).toEqual(["older", "newer"]);
  expect(deviceChats().map((chat) => chat.key)).toEqual(["codex:d1"]);
  // A context with none, or a malformed one, keeps what the page had.
  newTabHost({ newTab: { kind: "agent" } });
  newTabHost({ newTab: { kind: "agent", warm: "{" } });
  expect(warmNewTabSessions()).toHaveLength(2);
});

test("a device chats push the host already made wins over the carried ones", () => {
  setDeviceChats([{ key: "claude:pushed", harness: "claude", updatedAt: 9 }]);
  newTabHost({ newTab: { kind: "agent", warm: JSON.stringify({ sessions, device }) } });
  expect(deviceChats().map((chat) => chat.key)).toEqual(["claude:pushed"]);
});

test("the carried chats show only until the page's own list arrives", () => {
  expect(shownNewTabSessions({ sessions: [], link: "connected" as const, emitReason: "connected" }, sessions)).toBe(
    sessions,
  );
  expect(
    shownNewTabSessions(
      { sessions: [], listedSessions: true, link: "connected" as const, emitReason: "connected" },
      sessions,
    ),
  ).toBeUndefined();
  expect(
    shownNewTabSessions(
      { sessions: sessions.slice(0, 1), link: "connected" as const, emitReason: "connected" },
      sessions,
    ),
  ).toBeUndefined();
  expect(
    shownNewTabSessions({ sessions: [], link: "connected" as const, emitReason: "connected" }, []),
  ).toBeUndefined();
});

test("a local listed snapshot posts its newest chats once, coalesced", () => {
  // The post waits on a fake clock: the coalescing delay is the behavior.
  jest.useFakeTimers();
  const posts: string[] = [];
  const send = (warm: string) => posts.push(warm);
  // Not listed yet, or another machine's list: nothing to warm this Mac's pages with.
  publishWarmNewTab({ origin: "local", sessions }, send);
  publishWarmNewTab({ origin: "remote", listedSessions: true, sessions }, send);
  publishWarmNewTab({ origin: "local", listedSessions: true, sessions }, send);
  publishWarmNewTab({ origin: "local", listedSessions: true, sessions: [...sessions] }, send);
  // One post per two seconds while the list changes: not before.
  jest.advanceTimersByTime(1900);
  expect(posts).toHaveLength(0);
  jest.advanceTimersByTime(200);
  expect(posts).toHaveLength(1);
  // The post is the JSON text the host keeps as it is (it parses and re-encodes nothing).
  expect(typeof posts[0]).toBe("string");
  const posted = JSON.parse(posts[0] ?? "") as { sessions: { sessionId: string }[]; device: unknown[] };
  expect(posted.sessions.map((entry) => entry.sessionId)).toEqual(["newer", "older"]);
  // A device chats push posts again with them.
  setDeviceChats(device);
  jest.advanceTimersByTime(2100);
  expect(posts).toHaveLength(2);
  expect((JSON.parse(posts[1] ?? "") as { device: unknown[] }).device).toHaveLength(1);
});

// Review (#22261): a page whose daemon is down, or that reconnects, must not show the carried chats.
test("a disconnected page shows no carried chats", () => {
  expect(
    shownNewTabSessions({ sessions: [], link: "disconnected" as const, emitReason: "disconnected" }, sessions),
  ).toBeUndefined();
  expect(
    shownNewTabSessions({ sessions: [], link: "connected" as const, emitReason: "debug" }, sessions),
  ).toBeUndefined();
  expect(shownNewTabSessions({ sessions: [], link: "connected" as const, emitReason: "connected" }, sessions)).toBe(
    sessions,
  );
});

test("once the page's own connection lists, the carried chats are done for good", () => {
  newTabHost({ newTab: { kind: "agent", warm: JSON.stringify({ sessions }) } });
  expect(warmNewTabSessions()).toHaveLength(2);
  // A chat page lists too, and posts nothing.
  const posts: unknown[] = [];
  publishWarmNewTab({ origin: "local", listedSessions: true, sessions }, (warm) => posts.push(warm), false);
  expect(warmNewTabSessions()).toHaveLength(0);
  // A later adoption's context does not bring them back for a reconnect's empty first snapshot.
  newTabHost({ newTab: { kind: "agent", warm: JSON.stringify({ sessions }) } });
  expect(warmNewTabSessions()).toHaveLength(0);
  expect(posts).toHaveLength(0);
});
