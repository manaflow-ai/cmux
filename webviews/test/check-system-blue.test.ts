// The system-blue ratchet (scripts/cmux-next/check-system-blue.py, cx-wqn5): UI code paints the
// theme, never macOS's or WebKit's default blue or a fixed blue. It warns (style ratchets warn) and
// never fails. Runs the real script on temp trees and on this checkout.
import { afterAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { spawnSync } from "node:child_process";
import { mkdtempSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { prScope } from "./support/prScope";

const script = path.resolve(import.meta.dir, "../../scripts/cmux-next/check-system-blue.py");
setDefaultTimeout(30_000);
const roots: string[] = [];
afterAll(() => roots.forEach((root) => rmSync(root, { recursive: true, force: true })));

// The ratchet is intentionally whole-tree. On a pull request, only a new finding in a changed
// source file (or a change to the ratchet itself) should make the webviews lane red; an older
// finding on feat-cmux-next remains visible as a warning until its owner fixes it.
const scope = prScope({
  rules: [
    "webviews/test/check-system-blue.test.ts",
    "webviews/test/support/prScope.ts",
    "scripts/cmux-next/check-system-blue.py",
    // The baseline is tab-separated rather than a quoted list, so changing it owns every finding.
    "scripts/cmux-next/system-blue-baseline.tsv",
  ],
});

function tree(files: Record<string, string>, baseline = ""): { root: string; baseline: string } {
  const root = mkdtempSync(path.join(tmpdir(), "system-blue-"));
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
  const result = spawnSync("python3", [script, ...args], {
    encoding: "utf8",
    env: { ...process.env, GITHUB_ACTIONS: "" },
  });
  return { status: result.status, out: `${result.stdout}${result.stderr}` };
}

describe("check-system-blue", () => {
  test("theme tokens and non-blue colors pass quietly", () => {
    const t = tree({
      "webviews/src/a.css":
        ".a { accent-color: var(--cmux-accent, currentColor); color: #e0def4; border-color: #eb6f92; }",
      "Packages/macOS/CmuxNext/Sources/A/A.swift":
        "let ring = Palette.focusRing\nlet red = NSColor.systemRed\nlet group = GroupColor.automaticOrder + [.blue]",
    });
    const result = run(["--root", t.root, "--baseline", t.baseline]);
    expect(result.status).toBe(0);
    expect(result.out).toContain("check-system-blue: ok");
  });

  test("each kind of system accent or blue warns, and never fails", () => {
    for (const [name, text] of [
      ["webviews/src/a.css", ".a { accent-color: AccentColor; }"],
      ["webviews/src/b.css", ".b { outline-color: -webkit-focus-ring-color; }"],
      ["webviews/src/c.ts", 'export const link = "#0a84ff";'],
      ["webviews/src/d.css", ".d { color: rgb(0, 122, 255); }"],
      ["webviews/src/e.css", ".e { background: #0a84ffcc; }"],
      ["webviews/src/f.css", "* { caret-color: #0a84ff; }"],
      ["Packages/macOS/CmuxNext/Sources/A/D.swift", 'Image(systemName: "x").tint(.blue)'],
      ["Packages/macOS/CmuxNext/Sources/A/A.swift", "let ring = NSColor.keyboardFocusIndicatorColor"],
      ["Packages/macOS/CmuxNext/Sources/A/B.swift", 'Text("x").foregroundStyle(Color.accentColor)'],
      ["Packages/macOS/CmuxNext/Sources/A/C.swift", "let tint = NSColor.controlAccentColor"],
    ] as const) {
      const t = tree({ [name]: text });
      const result = run(["--root", t.root, "--baseline", t.baseline]);
      expect(result.status).toBe(0);
      expect(result.out).toContain(`${name}: 1 system-accent or blue`);
    }
  });

  test("theme data is not scanned, and a baseline row quiets a known file", () => {
    const t = tree(
      {
        "webviews/src/syntax-colors.ts": 'export const keyword = "#0a84ff";',
        "webviews/src/legacy.css": ".x { color: #007aff; }",
      },
      "webviews/src/legacy.css\t1\n",
    );
    expect(run(["--root", t.root, "--baseline", t.baseline]).out).toContain("check-system-blue: ok");
  });

  test("a malformed baseline row is ignored, not fatal", () => {
    const t = tree({ "webviews/src/a.css": ".a { color: #e0def4; }" }, "webviews/src/a.css 1\n");
    const result = run(["--root", t.root, "--baseline", t.baseline]);
    expect(result.status).toBe(0);
    expect(result.out).toContain("ignoring malformed baseline row");
  });

  test("this checkout is within its baseline", () => {
    const result = run([]);
    expect(result.status).toBe(0);
    const findings = [
      ...result.out.matchAll(/^\s+([^:\n]+): \d+ system-accent or blue literals, baseline \d+:.*$/gm),
    ].map(([, file]) => file!);
    expect(
      scope.owned(
        findings,
        (file) => ({ files: [file] }),
        (file) => file,
      ),
    ).toEqual([]);
  });
});
