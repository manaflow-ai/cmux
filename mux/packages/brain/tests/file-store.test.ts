import { afterEach, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { compact, FileMemoryStore, wake, zoom } from "../src/index.ts";

const dirs: string[] = [];
afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});
function store(): FileMemoryStore {
  const dir = mkdtempSync(join(tmpdir(), "mux-brain-"));
  dirs.push(dir);
  return new FileMemoryStore(join(dir, "memory"));
}
const commits = (dir: string) =>
  new TextDecoder()
    .decode(Bun.spawnSync(["git", "log", "--format=%s"], { cwd: dir }).stdout)
    .trim()
    .split("\n")
    .filter(Boolean);

test("the log and the summary tree are files in a git repo, committed per batch", async () => {
  const s = store();
  expect(await s.append(["a", "b\nwith newline", "c", "d"])).toBe(4);
  expect(await s.read(1, 2)).toEqual(["b with newline"]);
  expect(s.commit("prompt")).toBe(true);
  expect(s.commit("nothing changed")).toBe(false);
  await compact(s, [{ lo: 0, hi: 3 }], async ({ left, right }) => `${left}+${right}`);
  s.commit("compact");
  expect(readFileSync(join(s.dir, "TREE", "0-3.txt"), "utf8").trim()).toBe(
    "a+b with newline+c+d",
  );
  expect(commits(s.dir)).toEqual(["compact", "prompt"]);
  expect((await wake(s, 1)).text).toBe("#0-3 a+b with newline+c+d");
  expect(await zoom(s, { lo: 0, hi: 3 })).toEqual(["#0-1 a+b with newline", "#2-3 c+d"]);
  expect(await s.recall("^c$", 5)).toEqual([{ index: 2, line: "c" }]);
});

test("reopening the directory keeps the log", async () => {
  const s = store();
  await s.append(["kept"]);
  const again = new FileMemoryStore(s.dir);
  expect(await again.read(0, 1)).toEqual(["kept"]);
});
