import { afterAll, beforeAll, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import path from "node:path";
import { agentRead } from "../dev-server/agentGitHost";

const root = fs.realpathSync(fs.mkdtempSync(path.join(import.meta.dir, ".file-list-")));
const chat = path.join(root, "chat");
const outside = path.join(root, "outside");

beforeAll(() => {
  execFileSync("git", ["init", "-q", root]);
  fs.mkdirSync(path.join(chat, "src"), { recursive: true });
  fs.mkdirSync(outside);
  fs.writeFileSync(path.join(chat, "note.txt"), "chat file\n");
  fs.writeFileSync(path.join(chat, "src", "app.ts"), "export {};\n");
  fs.writeFileSync(path.join(chat, ".gitignore"), "ignored.txt\n");
  fs.writeFileSync(path.join(chat, "ignored.txt"), "ignored\n");
  fs.writeFileSync(path.join(outside, "private.txt"), "outside file\n");
  fs.symlinkSync(outside, path.join(chat, "escape"));
  fs.symlinkSync(path.join(chat, "src"), path.join(chat, "inside"));
});

afterAll(() => fs.rmSync(root, { recursive: true, force: true }));

test("file.list lists the chat folder and its children without ignored files", async () => {
  const listed = await agentRead("file.list", { cwd: chat }, chat);
  expect(listed).toEqual({
    entries: [
      { name: "escape", kind: "directory" },
      { name: "inside", kind: "directory" },
      { name: "src", kind: "directory" },
      { name: ".gitignore", kind: "file" },
      { name: "note.txt", kind: "file" },
    ],
    truncated: false,
  });
  expect(await agentRead("file.list", { cwd: chat, path: path.join(chat, "src") }, chat)).toEqual({
    entries: [{ name: "app.ts", kind: "file" }],
    truncated: false,
  });
});

for (const [name, folder] of [
  ["parent traversal", `${chat}/../outside`],
  ["an escaping directory symlink", path.join(chat, "escape")],
]) {
  test(`file.list refuses ${name} instead of returning outside file names`, async () => {
    await expect(agentRead("file.list", { cwd: chat, path: folder }, chat)).rejects.toMatchObject({
      code: "validation.invalid",
    });
  });
}

test("file.list resolves a directory symlink that stays inside the chat folder", async () => {
  expect(await agentRead("file.list", { cwd: chat, path: path.join(chat, "inside") }, chat)).toEqual({
    entries: [{ name: "app.ts", kind: "file" }],
    truncated: false,
  });
});
