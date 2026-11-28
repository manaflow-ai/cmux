// People's readers (teamDirectoryModel.ts): each `_acpmux/team/*` answer narrows to its shape, and a
// failed read names why from the RPC error acpmux sends (server/team.rs, server/team_directory.rs).
import { expect, test } from "bun:test";
import { directoryReason, readNavigator, readPicked, readSessionInfo } from "./teamDirectoryModel";

test("a failed read names its reason", () => {
  expect(directoryReason({ code: -32602, message: "x", data: { reason: "team_messaging_disabled" } })).toBe("off");
  expect(directoryReason(new Error("team messaging is off: meshRelay in config.json names no hub"))).toBe("off");
  expect(directoryReason({ code: -32602, message: "x", data: { reason: "team_directory_unavailable" } })).toBe(
    "notReady",
  );
  expect(directoryReason({ code: -32602, message: "x", data: { reason: "team_directory_unknown_viewer" } })).toBe(
    "unknownViewer",
  );
  expect(directoryReason({ code: -32602, message: "x", data: { reason: "team_directory_not_visible" } })).toBe(
    "notVisible",
  );
  expect(directoryReason({ code: -32601, message: "Method not found" })).toBe("older");
  expect(directoryReason(new Error("socket closed"))).toBe("failed");
});

test("the navigator keeps a space's preview and its live totals", () => {
  const read = readNavigator({
    teams: [{ id: "core", name: "Core", current: true, unread: 0 }],
    spaces: [
      { id: "s", title: "S", kind: "project", unread: 0, open: 0, people: [{ principalId: "a" }], peopleLive: 12 },
    ],
  });
  expect(read?.spaces[0]?.people).toHaveLength(1);
  expect(read?.spaces[0]?.agents).toEqual([]);
  expect(read?.spaces[0]?.peopleLive).toBe(12);
  expect(read?.hits).toEqual([]);
  expect(readNavigator({ teams: [] })).toBeUndefined();
});

test("Send to and a session's links narrow or read nothing", () => {
  expect(readPicked({ candidates: [] })).toEqual({ resolved: [], candidates: [] });
  expect(readPicked(null)).toBeUndefined();
  const info = readSessionInfo({ session: { kind: "session", source: "cmux", id: "x" } });
  expect(info?.threads).toEqual([]);
  expect(info?.actions).toEqual([]);
  expect(readSessionInfo({})).toBeUndefined();
});
