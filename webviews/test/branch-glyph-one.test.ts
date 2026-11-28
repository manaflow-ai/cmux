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
