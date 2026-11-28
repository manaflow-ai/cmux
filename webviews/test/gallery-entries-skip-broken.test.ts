// whats-new-gallery.yml renders each What's New highlight's gallery state, and its manifest and notes steps load every
// gallery file. On 2026-11-27 one duplicate `const name` in an unrelated ClaudeConnectRow.gallery.tsx failed 10 of its
// runs (05:14Z to 08:18Z), so four Improved highlights shipped in nightly 4598742452601 with no picture. With
// skipBroken a file that fails to load is left out; without it (the tests' default) it still fails.
import { expect, test } from "bun:test";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { loadEntrySources } from "../scripts/gallery/entries";

function tree(): string {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "gallery-skip-broken-"));
  fs.mkdirSync(path.join(dir, "a"));
  fs.writeFileSync(
    path.join(dir, "a/Good.gallery.ts"),
    'export default { id: "a.good", title: "Good", area: "A", covers: [], variants: { idle: {} } };\n',
  );
  // The 2026-11-27 shape: a name declared twice, a parse error at load.
  fs.writeFileSync(
    path.join(dir, "a/Broken.gallery.ts"),
    'const name = (s: string) => s;\nconst name = (s: string) => s;\nexport default { id: "a.broken", name };\n',
  );
  fs.writeFileSync(path.join(dir, "a/NoDefault.gallery.ts"), "export const x = 1;\n");
  return dir;
}

test("skipBroken leaves out a gallery file that fails to load and keeps the rest", async () => {
  const dir = tree();
  try {
    const loaded = await loadEntrySources({ dir, skipBroken: true });
    expect(loaded.map(({ entry, path: file }) => [entry.id, file])).toEqual([["a.good", "src/a/Good.gallery.ts"]]);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});

test("without skipBroken a gallery file that fails to load still fails the load", async () => {
  const dir = tree();
  try {
    await expect(loadEntrySources({ dir })).rejects.toBeDefined();
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
});
