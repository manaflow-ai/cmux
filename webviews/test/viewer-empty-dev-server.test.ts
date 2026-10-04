// The dev host of the viewer empty states (dev-server/viewerEmptyHost.ts): the recents file and
// the fallback picker's listing, which stays inside the allowed roots.
import { afterAll, describe, expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import {
  ListingRefused,
  devRecents,
  devStateDirectory,
  gitTopLevel,
  listPickerDirectory,
  sourceKind,
  sourceQuery,
} from "../dev-server/viewerEmptyHost";

const scratch = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "viewer-empty-dev-")));
afterAll(() => fs.rmSync(scratch, { recursive: true, force: true }));

const home = path.join(scratch, "home");
for (const dir of ["fun/repo/.git", "fun/plain", ".secret", "Documents/.git"]) {
  fs.mkdirSync(path.join(home, dir), { recursive: true });
}
fs.writeFileSync(path.join(home, "fun/notes.md"), "# n\n");
fs.writeFileSync(path.join(home, "fun/a.txt"), "a\n");
fs.mkdirSync(path.join(scratch, "outside"));

describe("picker listing", () => {
  const list = (requested: string | null, mode: "folder" | "file" = "folder", hidden = false) =>
    listPickerDirectory(requested, { roots: [home], home, mode, hidden });

  test("home by default; hidden entries only on request; at the root there is no parent", () => {
    const listing = list(null);
    expect(listing.path).toBe(home);
    expect(listing.parent).toBeNull();
    expect(listing.entries.map((entry) => entry.name)).toEqual(["Documents", "fun"]);
    expect(list("~", "folder", true).entries.map((entry) => entry.name)).toEqual([".secret", "Documents", "fun"]);
  });

  test("folders are marked as git repositories; file mode adds markdown files only", () => {
    const fun = list("~/fun", "file");
    expect(fun.parent).toBe(home);
    expect(fun.entries).toEqual([
      { name: "notes.md", path: path.join(home, "fun/notes.md"), kind: "file" },
      { name: "plain", path: path.join(home, "fun/plain"), kind: "dir", git: undefined },
      { name: "repo", path: path.join(home, "fun/repo"), kind: "dir", git: true },
    ]);
    expect(list(path.join(home, "fun")).entries.map((entry) => entry.name)).toEqual(["plain", "repo"]);
  });

  test("privacy-guarded home folders are listed without looking inside", () => {
    expect(list(null).entries.find((entry) => entry.name === "Documents")?.git).toBeUndefined();
  });

  test("a folder outside the roots, or a path escaping them, is refused", () => {
    expect(() => list(path.join(scratch, "outside"))).toThrow(ListingRefused);
    expect(() => list(`${home}/../outside`)).toThrow(ListingRefused);
    expect(() => list("/")).toThrow(ListingRefused);
    expect(() => list(path.join(home, "missing"))).toThrow(ListingRefused);
  });
});

describe("recents file", () => {
  test("records newest first, dedupes, keeps the last source, lists only existing paths", () => {
    let clock = 1000;
    const recents = devRecents(path.join(scratch, "state"), () => clock);
    recents.record("diff", { path: path.join(home, "fun/repo"), source: "staged" });
    clock = 2000;
    recents.record("diff", { path: path.join(home, "fun/plain") });
    clock = 3000;
    recents.record("diff", { path: path.join(home, "fun/repo") });
    recents.record("diff", { path: path.join(home, "gone") });
    recents.record("markdown", { path: path.join(home, "fun/notes.md") });
    expect(recents.list("diff")).toEqual([
      { path: path.join(home, "fun/repo"), openedAt: 3000, source: "staged" },
      { path: path.join(home, "fun/plain"), openedAt: 2000 },
    ]);
    expect(recents.list("markdown").map((item) => item.path)).toEqual([path.join(home, "fun/notes.md")]);
  });

  test("the state folder is the slot's, else one per port", () => {
    expect(devStateDirectory(4187, { CMUX_WEBVIEWS_DEV_STATE_DIR: "/tmp/acpdev-7" })).toBe("/tmp/acpdev-7");
    expect(devStateDirectory(4187, {})).toBe(path.join(os.tmpdir(), "cmux-webviews-dev-4187"));
  });
});

describe("diff open", () => {
  test("the git top level of a folder inside a repository", () => {
    const repo = path.join(scratch, "real-repo");
    fs.mkdirSync(path.join(repo, "sub"), { recursive: true });
    execFileSync("git", ["init", "-q", repo]);
    expect(gitTopLevel(path.join(repo, "sub"))).toBe(repo);
    expect(gitTopLevel(path.join(scratch, "outside"))).toBeUndefined();
  });

  test("a session source becomes the dev config query and a recents kind", () => {
    const base = () => "origin/main";
    expect(sourceQuery({ kind: "branch", repoRoot: "/r" }, "/r", base).toString()).toBe(
      "repo=%2Fr&source=branch&base=origin%2Fmain",
    );
    expect(sourceQuery({ kind: "branch", repoRoot: "/r", baseRef: "HEAD" }, "/r", base).get("base")).toBe("HEAD");
    expect(sourceQuery({ kind: "staged", repoRoot: "/r" }, "/r", base).toString()).toBe("repo=%2Fr&source=staged");
    expect(sourceKind({ kind: "branch", baseRef: "HEAD" })).toBe("uncommitted");
    expect(sourceKind({ kind: "branch", baseRef: "main" })).toBe("branch");
    expect(sourceKind({ kind: "unstaged" })).toBe("unstaged");
  });
});
