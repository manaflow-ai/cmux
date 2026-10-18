import { expect, test } from "bun:test";
import { sidebarSections } from "../src/agent-session/acpmux/sessionList";

const session = (id: string, cwd: string) => ({
  sessionId: id,
  displayTitle: id,
  cwd,
  updatedAt: 1,
});

test("ungrouped sidebar sections skip project grouping", () => {
  const sessions = [session("a", "/tmp/one"), session("b", "/tmp/two")];
  expect(sidebarSections(sessions, "", false)).toMatchObject({ pinned: [], groups: [], active: sessions });
  expect(sidebarSections(sessions, "", true).groups).toHaveLength(2);
});

test("ungrouped sidebar sections keep archived, side, and folded chats out", () => {
  const parent = session("parent", "/tmp/one");
  const child = { ...session("child", "/tmp/one"), spawnedBy: "parent" };
  const archived = { ...session("archived", "/tmp/one"), archived: true };
  const side = { ...session("side", "/tmp/one"), side: true };
  expect(sidebarSections([parent, child, archived, side], "", false).active.map((entry) => entry.sessionId)).toEqual([
    "parent",
  ]);
});
