// One branch glyph everywhere NEXT draws a branch. Leo, 2026-11-22 (ask-f87d5d43b4): "use the same
// branch icon as chatgpt and claude". The composer had it (cmux#52815) while the folder picker's
// worktree and branch rows still drew an older three-node glyph. Every branch icon now renders
// BranchGlyph (src/agent-session/acpmux/BranchGlyph.tsx); this fails if a surface draws its own svg again.
import { expect, test } from "bun:test";
import { readdirSync, readFileSync, statSync } from "node:fs";
import path from "node:path";

const root = path.resolve(import.meta.dir, "../src");
const files = (dir: string): string[] =>
  readdirSync(dir).flatMap((name) => {
    const full = path.join(dir, name);
    return statSync(full).isDirectory() ? files(full) : /\.tsx$/.test(name) ? [full] : [];
  });

test("every BranchIcon renders the shared BranchGlyph, not its own svg", () => {
  const own: string[] = [];
  for (const file of files(root)) {
    if (file.endsWith("BranchGlyph.tsx")) continue;
    const source = readFileSync(file, "utf8");
    for (const match of source.matchAll(/function (\w*Branch\w*(?:Icon|Glyph))\([^)]*\)[^{]*\{([\s\S]*?)\n\}/g)) {
      if (/<svg/.test(match[2])) own.push(`${path.relative(root, file)}: ${match[1]}`);
    }
  }
  expect(own).toEqual([]);
});

// The Mac draws the pack's git.branch (the same trunk, curve and two nodes) for a branch. Its folder
// picker names SF arrow.triangle.branch for git repositories (PickerSession+Items/Places), and the
// palette draws a pack icon in place of an SF symbol only when that icon overrides it.
test("the Mac palette's git-repository symbol draws the pack's git.branch", () => {
  const catalog = JSON.parse(
    readFileSync(path.resolve(import.meta.dir, "../src/agent-session/acpmux/icons/iconCatalog.json"), "utf8"),
  ) as { name: string; overrides?: string[] }[] | { icons: { name: string; overrides?: string[] }[] };
  const entries = Array.isArray(catalog) ? catalog : catalog.icons;
  const owners = entries
    .filter((entry) => entry.overrides?.includes("arrow.triangle.branch"))
    .map((entry) => entry.name);
  expect(owners).toEqual(["git.branch"]);
});
