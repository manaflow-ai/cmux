// l10n-allow-file: test fixtures.
import { expect, test } from "bun:test";
import type { AcpmuxSessionEntry } from "../sessionList";
import { alsoHere, ALSO_HERE_WINDOW_MS } from "./alsoHere";
import { alsoHereRow } from "./AlsoHereSection";

const NOW = 10 * ALSO_HERE_WINDOW_MS;
const chat = (sessionId: string, more: Partial<AcpmuxSessionEntry> = {}): AcpmuxSessionEntry => ({
  sessionId,
  name: sessionId,
  status: "running",
  activityAt: NOW - 60_000,
  ...more,
});

const ME = chat("me", { worktree: "/w/cmux-a", cwd: "/w/cmux-a", branch: "lane/who-else" });

test("a chat in the same worktree or a folder inside it is also here; another folder is not", () => {
  const all = [
    ME,
    chat("sub-folder", { cwd: "/w/cmux-a/webviews" }),
    chat("same-worktree", { worktree: "/w/cmux-a", cwd: "/w/cmux-a/cmux-tui", branch: "main" }),
    chat("elsewhere", { cwd: "/w/cmux-b", branch: "lane/other" }),
    chat("prefix-only", { cwd: "/w/cmux-ab" }),
  ];
  expect(alsoHere("me", all, NOW).map((r) => r.entry.sessionId)).toEqual(["sub-folder", "same-worktree"]);
});

test("the same feature branch in another clone counts, a shared branch does not", () => {
  const all = [
    ME,
    chat("other-clone", { worktree: "/x/cmux", branch: "lane/who-else", peer: "big-red" }),
    chat("on-main", { cwd: "/x/cmux", branch: "main" }),
  ];
  expect(alsoHere("me", all, NOW)).toEqual([{ entry: all[1]!, why: "branch" }]);
  const onMain = { ...ME, branch: "feat-cmux-next" };
  const twin = chat("twin", { cwd: "/x/cmux", branch: "feat-cmux-next" });
  expect(alsoHere("me", [onMain, twin], NOW)).toEqual([]);
});

test("this chat's own family, closed, archived, side and day-old chats are not someone else", () => {
  const here = { cwd: "/w/cmux-a" };
  const all = [
    { ...ME, startedBy: "coord" },
    chat("coord", here),
    chat("child", { ...here, startedBy: "me" }),
    chat("grandchild", { ...here, spawnedBy: "child" }),
    chat("fork", { ...here, parentId: "me" }),
    chat("closed", { ...here, status: "closed" }),
    chat("archived", { ...here, archived: true }),
    chat("side", { ...here, side: true }),
    chat("old", { ...here, status: "idle", activityAt: NOW - 2 * ALSO_HERE_WINDOW_MS }),
    chat("old-but-running", { ...here, activityAt: NOW - 2 * ALSO_HERE_WINDOW_MS }),
  ];
  expect(alsoHere("me", all, NOW).map((r) => r.entry.sessionId)).toEqual(["old-but-running"]);
});

test("a peer's chat in a folder of the same path on another machine is not here", () => {
  const all = [ME, chat("far", { cwd: "/w/cmux-a", peer: "big-red" })];
  expect(alsoHere("me", all, NOW)).toEqual([]);
});

test("a row names a peer's chat with its machine", () => {
  const row = alsoHereRow({
    entry: chat("x", { peer: "big-red", title: "crate split", harness: "codex" }),
    why: "branch",
  });
  expect(row).toMatchObject({ sessionId: "x", title: "big-red/crate split", harness: "codex", state: "running" });
});
