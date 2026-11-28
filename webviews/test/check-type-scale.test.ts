// The type-scale ratchet (scripts/cmux-next/check-type-scale.py, webviews/src/ui/README.md "Type
// scale"): a new literal font size fails; the sizes already in the tree sit in a baseline that may only
// go down, and a lower count must lower the baseline. Runs the real script on temp trees and on this
// checkout, and checks that the shared menus and the agent pane pickers use the tokens.
import { afterAll, describe, expect, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

const script = path.resolve(import.meta.dir, "../../scripts/cmux-next/check-type-scale.py");
const src = path.resolve(import.meta.dir, "../src");
const roots: string[] = [];
afterAll(() => roots.forEach((root) => rmSync(root, { recursive: true, force: true })));

function tree(files: Record<string, string>, baseline = ""): { root: string; baseline: string } {
  const root = mkdtempSync(path.join(tmpdir(), "type-scale-"));
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

describe("check-type-scale", () => {
  test("tokens, inherit and relative sizes pass", () => {
    const t = tree({
      "src/a.css":
        ".a { font-size: var(--text-body); } .b { font: inherit; } .c { font-size: 0.85em; } .d { font-size: 90%; }",
      "src/b.tsx": 'export const B = () => <div className="text-detail text-content" style={{ fontSize: "1.1em" }} />;',
      "src/pages/shared/desktop.css": ":root { --text-body: 13px; } .tip { font: 12px/16px system-ui; }",
    });
    expect(run(["--root", t.root, "--baseline", t.baseline]).status).toBe(0);
  });

  test("each kind of literal size fails without a baseline row", () => {
    for (const [name, text] of [
      ["src/a.css", ".a { font-size: 12px; }"],
      ["src/b.css", ".b { font: 13px/18px system-ui; }"],
      ["src/c.css", ".c { font-size: 0.8rem; }"],
      ["src/d.tsx", 'export const D = () => <span className="text-[12px]" />;'],
      ["src/e.tsx", "export const E = () => <span style={{ fontSize: 12 }} />;"],
      ["src/f.ts", 'el.style.fontSize = "11px";'],
    ] as const) {
      const t = tree({ [name]: text });
      const result = run(["--root", t.root, "--baseline", t.baseline]);
      expect(result.status, name).toBe(1);
      expect(result.out).toContain("raw font sizes");
    }
  });

  test("the baseline only moves down", () => {
    const rows = "# header\nsrc/a.css\tsize\t2\n";
    const fewer = tree({ "src/a.css": ".a { font-size: 12px; }" }, rows);
    expect(run(["--root", fewer.root, "--baseline", fewer.baseline]).status).toBe(1);
    const more = tree({ "src/a.css": ".a { font-size: 12px; } .b { font-size: 13px; } .c { font-size: 14px; }" }, rows);
    expect(run(["--root", more.root, "--baseline", more.baseline, "--update-baseline"]).status).toBe(1);
    expect(run(["--root", fewer.root, "--baseline", fewer.baseline, "--update-baseline"]).status).toBe(0);
    expect(readFileSync(fewer.baseline, "utf8")).toContain("src/a.css\tsize\t1");
  });

  test("this checkout matches its baseline", () => {
    const result = run([]);
    expect(result.out).toContain("check-type-scale: ok");
    expect(result.status).toBe(0);
  });

  test("the shared menus and the agent pane pickers use the type tokens", () => {
    const read = (file: string) => readFileSync(path.join(src, file), "utf8");
    const literal = /font-size\s*:\s*\d*\.?\d+(px|rem)|(?<![\w-])font\s*:\s*\d*\.?\d+px|text-\[\d+px\]/;
    for (const file of [
      "ui/ui.css",
      "agent-session/acpmux/ModelPicker.tsx",
      "agent-session/acpmux/modelPicker.css",
      "agent-session/acpmux/composerLocation.css",
      "agent-session/acpmux/composerControls.css",
      "agent-session/acpmux/header/header.css",
      "agent-session/acpmux/summary/summary.css",
    ])
      expect(literal.test(read(file)), file).toBe(false);
    expect(read("ui/ui.css")).toContain("font-size: var(--text-control)");
    expect(read("agent-session/acpmux/styles.css")).toMatch(/\.acpmux-menu\{[^}]*font-size:var\(--text-control\)/);
    const tokens = read("pages/shared/desktop.css");
    for (const step of ["caption", "detail", "body", "control", "title", "heading", "content"])
      expect(tokens).toContain(`--text-${step}:`);
  });
});
