// The chat header's Changes (±) in a folder outside a repository opened only the folder picker in the
// command palette, never a diff on the right (Leo, 2026-10-28: "this changes button. This doesn't really
// do anything. All it does is open up the command palette, and it doesn't open up the diff viewer on the
// right side"). There it now opens the last turn's changes in the page, on the chat's right, as the
// edited-files card does; in a repository it still opens the folder's diff tab beside the chat.
import { expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { headerChangesInPlace } from "../src/agent-session/acpmux/turnChanges/viewChanges";

const status = (root?: string) => async () => (root ? { root } : { error: "not_a_repository" });

test("a folder outside a repository opens the turn's changes in the page", async () => {
  expect(await headerChangesInPlace("/Users/me/notes", false, status())).toBe(true);
});

test("a failed status read opens them in the page, not the palette", async () => {
  expect(await headerChangesInPlace("/Users/me/notes", false, () => Promise.reject(new Error("offline")))).toBe(true);
});

test("a folder in a repository opens the folder's diff tab", async () => {
  expect(await headerChangesInPlace("/Users/me/repo/src", false, status("/Users/me/repo"))).toBe(false);
});

test("a diff tab Changes opened closes through the app", async () => {
  expect(await headerChangesInPlace("/Users/me/notes", true, status())).toBe(false);
});

test("a chat with no folder on this Mac keeps the app's path", async () => {
  expect(await headerChangesInPlace(undefined, false, status())).toBe(false);
});

test("the header's Changes goes through the check", () => {
  const app = readFileSync(new URL("../src/agent-session/acpmux/App.tsx", import.meta.url), "utf8");
  expect(app).toContain("onChanges={toggleChanges}");
  expect(app).toMatch(/const toggleChanges = [\s\S]{0,200}headerChangesInPlace\(/);
});
