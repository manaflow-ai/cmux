// The layer ratchet (scripts/cmux-next/check-layers.py, webviews/src/ui/README.md "Layers and
// transparency"): a new raw z-index or a new backdrop-filter without a reduced-transparency fallback
// fails; the counts already in the tree sit in a baseline that may only go down, and a lower count
// must lower the baseline. Runs the real script on a temp tree and on this checkout.
import { afterAll, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

const script = path.resolve(import.meta.dir, "../../scripts/cmux-next/check-layers.py");
const roots: string[] = [];
afterAll(() => roots.forEach((root) => rmSync(root, { recursive: true, force: true })));

function tree(files: Record<string, string>, baseline = ""): { root: string; baseline: string } {
  const root = mkdtempSync(path.join(tmpdir(), "layers-"));
  roots.push(root);
  for (const [name, text] of Object.entries(files)) {
    mkdirSync(path.dirname(path.join(root, name)), { recursive: true });
    writeFileSync(path.join(root, name), text);
  }
  const file = path.join(root, "baseline.tsv");
  writeFileSync(file, baseline);
  return { root, baseline: file };
}

function run(args: string[]) {
  const result = spawnSync("python3", [script, ...args], { encoding: "utf8" });
  return { status: result.status, out: `${result.stdout}${result.stderr}` };
}

describe("check-layers", () => {
  test("token and variable layers pass", () => {
    const t = tree({
      "src/a.css": ".a { z-index: var(--layer-dropdown); } .b { z-index: auto; } .c { z-index: 0; }",
      "src/b.tsx":
        'export const B = () => <div className="z-(--layer-tooltip) relative" style={{ zIndex: "var(--layer-modal)" }} />;',
    });
    expect(run(["--root", t.root, "--baseline", t.baseline]).status).toBe(0);
  });

  test("a new raw z-index fails in CSS, Tailwind classes and inline styles", () => {
    for (const text of [
      ".a { z-index: 51; }",
      '<div className="flex z-50" />',
      '<div className="z-[3]" />',
      "el.style.zIndex = '9';",
      "const s = { zIndex: 4 };",
    ]) {
      const t = tree({ [`src/x.${text.startsWith(".") ? "css" : "tsx"}`]: text });
      const result = run(["--root", t.root, "--baseline", t.baseline]);
      expect(result.status, text).toBe(1);
      expect(result.out).toContain("raw z-index");
    }
  });

  test("a backdrop-filter needs a reduced-transparency fallback in the same file", () => {
    const bare = tree({ "src/glass.css": ".g { backdrop-filter: blur(20px); }" });
    expect(run(["--root", bare.root, "--baseline", bare.baseline]).out).toContain("reduced-transparency");
    const ok = tree({
      "src/glass.css":
        ".g { backdrop-filter: blur(20px); } @media (prefers-reduced-transparency: reduce) { .g { backdrop-filter: none; background: var(--x); } }",
    });
    expect(run(["--root", ok.root, "--baseline", ok.baseline]).status).toBe(0);
  });

  test("the baseline holds existing counts and may only go down", () => {
    const files = { "src/old.css": ".a { z-index: 5; } .b { z-index: 6; }" };
    const held = tree(files, "src/old.css\tz\t2\n");
    expect(run(["--root", held.root, "--baseline", held.baseline]).status).toBe(0);
    const grew = tree(
      { "src/old.css": ".a { z-index: 5; } .b { z-index: 6; } .c { z-index: 7; }" },
      "src/old.css\tz\t2\n",
    );
    expect(run(["--root", grew.root, "--baseline", grew.baseline]).status).toBe(1);
    const shrank = tree(
      { "src/old.css": ".a { z-index: var(--layer-raised); } .b { z-index: 6; }" },
      "src/old.css\tz\t2\n",
    );
    const result = run(["--root", shrank.root, "--baseline", shrank.baseline]);
    expect(result.status).toBe(1);
    expect(result.out).toContain("lower the baseline");
    expect(run(["--root", shrank.root, "--baseline", shrank.baseline, "--update-baseline"]).status).toBe(0);
    expect(run(["--root", shrank.root, "--baseline", shrank.baseline]).status).toBe(0);
    expect(run(["--root", grew.root, "--baseline", grew.baseline, "--update-baseline"]).status).toBe(1);
  });

  test("this checkout passes with its baseline", () => {
    const result = run([]);
    expect(result.status, result.out).toBe(0);
  });
});
