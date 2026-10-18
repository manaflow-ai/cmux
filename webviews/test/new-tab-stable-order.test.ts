// l10n-allow-file: test fixtures.
// Chats that share a timestamp keep their places: the daemon may report two in the same
// millisecond, and a live update that reorders the snapshot must not make the rows trade places
// (re-cut from #21318).
import { expect, test } from "bun:test";
import { recentSessions } from "../src/agent-session/acpmux/NewTabPage";
import type { DeviceChat } from "../src/agent-session/acpmux/newtab/deviceChats";
import { recentChatCards } from "../src/agent-session/acpmux/newtab/screenModel";
import type { AcpmuxSessionEntry } from "../src/agent-session/acpmux/sessionList";

const T0 = Date.UTC(2026, 9, 13, 15, 0);

function lane(fields: Partial<AcpmuxSessionEntry> & Record<string, unknown>): AcpmuxSessionEntry {
  return {
    sessionId: "lane-1",
    name: "lane",
    harness: "claude",
    status: "ready",
    cwd: "/Users/you/src/cmux",
    updatedAt: T0,
    ...fields,
  } as AcpmuxSessionEntry;
}

test("same-time sessions keep one order whatever order the snapshot lists them in", () => {
  const sessions = [
    lane({ sessionId: "chat-b", name: "Second chat" }),
    lane({ sessionId: "chat-a", name: "First chat" }),
  ];
  const ids = (list: AcpmuxSessionEntry[]) => recentSessions(list, 2, false).map((entry) => entry.sessionId);
  expect(ids(sessions)).toEqual(["chat-a", "chat-b"]);
  expect(ids([...sessions].reverse())).toEqual(["chat-a", "chat-b"]);
});

test("same-time device chats keep one order whatever order the host pushes them in", () => {
  const device: DeviceChat[] = [
    { key: "claude:b", harness: "claude", title: "Second", updatedAt: T0 },
    { key: "claude:a", harness: "claude", title: "First", updatedAt: T0 },
  ];
  const keys = (list: DeviceChat[]) => recentChatCards([], T0, undefined, list).map((card) => card.chatKey);
  expect(keys(device)).toEqual(["claude:a", "claude:b"]);
  expect(keys([...device].reverse())).toEqual(["claude:a", "claude:b"]);
});

test("same-time children keep one order under their parent", () => {
  const sessions = [
    lane({ sessionId: "parent", name: "Parent", updatedAt: T0 + 1 }),
    lane({ sessionId: "child-b", name: "Child B", spawnedBy: "parent" }),
    lane({ sessionId: "child-a", name: "Child A", spawnedBy: "parent" }),
  ];
  const children = (list: AcpmuxSessionEntry[]) =>
    recentChatCards(list, T0)[0]?.children?.map((card) => card.sessionId);
  expect(children(sessions)).toEqual(["child-a", "child-b"]);
  expect(children([sessions[0]!, sessions[2]!, sessions[1]!])).toEqual(["child-a", "child-b"]);
});
