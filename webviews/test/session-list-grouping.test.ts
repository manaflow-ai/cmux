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
  expect(sidebarSections(sessions, "", false)).toMatchObject({ pinned: [], groups: [] });
  expect(sidebarSections(sessions, "", true).groups).toHaveLength(2);
});
