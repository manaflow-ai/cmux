// The recent chats a New Tab page's context carries (`warm`, newtab/warmSnapshot.ts): what a page
// of this Mac listed last, so the next page's first frame lists them (Leo 2026-10-19: the recent
// chats flickered as a new workspace opened). The page lists them until its own list arrives.
import { afterEach, expect, test } from "bun:test";
import { newTabHost } from "../src/agent-session/acpmux/NewTabPage";
import { deviceChats, setDeviceChats } from "../src/agent-session/acpmux/newtab/deviceChats";
import {
  publishWarmNewTab,
  resetWarmNewTabForTests,
  shownNewTabSessions,
  warmNewTabSessions,
} from "../src/agent-session/acpmux/newtab/warmSnapshot";
import { session } from "../src/gallery/fixtures/acpmux";

afterEach(() => {
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
  expect(shownNewTabSessions({ sessions: [] }, sessions)).toBe(sessions);
  expect(shownNewTabSessions({ sessions: [], listedSessions: true }, sessions)).toBeUndefined();
  expect(shownNewTabSessions({ sessions: sessions.slice(0, 1) }, sessions)).toBeUndefined();
  expect(shownNewTabSessions({ sessions: [] }, [])).toBeUndefined();
});

test("a local listed snapshot posts its newest chats once, coalesced", async () => {
  const posts: unknown[] = [];
  const send = (warm: unknown) => posts.push(warm);
  // Not listed yet, or another machine's list: nothing to warm this Mac's pages with.
  publishWarmNewTab({ origin: "local", sessions }, send);
  publishWarmNewTab({ origin: "remote", listedSessions: true, sessions }, send);
  publishWarmNewTab({ origin: "local", listedSessions: true, sessions }, send);
  publishWarmNewTab({ origin: "local", listedSessions: true, sessions: [...sessions] }, send);
  await Bun.sleep(500);
  expect(posts).toHaveLength(1);
  const posted = posts[0] as { sessions: { sessionId: string }[]; device: unknown[] };
  expect(posted.sessions.map((entry) => entry.sessionId)).toEqual(["newer", "older"]);
  // A device chats push posts again with them.
  setDeviceChats(device);
  await Bun.sleep(500);
  expect(posts).toHaveLength(2);
  expect((posts[1] as { device: unknown[] }).device).toHaveLength(1);
});
