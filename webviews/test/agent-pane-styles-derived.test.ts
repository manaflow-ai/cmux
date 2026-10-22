// The agent pane's page styles come from the bundle's own imports (bundle.mjs --css-inputs, in the
// order the modules load them), not from a hand-written list in build-agent-pane-web.sh. A list
// broke base each time a component imported a new sheet: ui/wave.css (#23995, fixed on base in
// 78c71ce7477) and inspector/ContextSection.css (5b32501aeb0). Here a fixture entry imports the
// pane and a sheet the script has never heard of, and the page's styles carry it, with no script edit.
import { afterAll, describe, expect, setDefaultTimeout, test } from "bun:test";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

setDefaultTimeout(180_000);

const webviews = path.resolve(import.meta.dir, "..");
const script = path.resolve(webviews, "../scripts/cmux-next/build-agent-pane-web.sh");
const work = fs.mkdtempSync(path.join(os.tmpdir(), "agent-pane-styles-derived-"));
afterAll(() => fs.rmSync(work, { recursive: true, force: true }));

function build(flag: "--styles" | "--sheets", entry?: string): string {
  const out = path.join(work, `${flag.slice(2)}-${entry ? path.basename(entry) : "pane"}.txt`);
  const run = spawnSync("sh", [script, flag, out, ...(entry ? ["--entry", entry] : [])], {
    cwd: webviews,
    encoding: "utf8",
  });
  expect(run.status, run.stderr).toBe(0);
  return fs.readFileSync(out, "utf8");
}

describe("agent pane page styles", () => {
  test("a stylesheet a new module imports ships with no edit to build-agent-pane-web.sh", () => {
    // The fixture: an entry that loads the pane, then a component sheet that @imports a part of its own.
    fs.writeFileSync(path.join(work, "fixture-derived-part.css"), ".fixture-derived-part { color: red; }\n");
    fs.writeFileSync(
      path.join(work, "fixture-derived.css"),
      '@import "./fixture-derived-part.css";\n.fixture-derived-sheet { color: blue; }\n',
    );
    const entry = path.join(work, "entry.ts");
    fs.writeFileSync(
      entry,
      `import ${JSON.stringify(path.join(webviews, "src/agent-session/acpmux/main.tsx"))};\nimport "./fixture-derived.css";\n`,
    );
    expect(fs.readFileSync(script, "utf8")).not.toContain("fixture-derived");

    const styles = build("--styles", entry);
    const part = styles.indexOf(".fixture-derived-part");
    const sheet = styles.indexOf(".fixture-derived-sheet");
    // The imported part goes in just before the sheet that imports it; no @import reaches the page.
    expect(part).toBeGreaterThan(0);
    expect(sheet).toBeGreaterThan(part);
    expect(styles.match(/^@import .*$/gm) ?? []).toEqual([]);
    // After the desktop layer, before Tailwind's utilities (which come last).
    expect(sheet).toBeGreaterThan(styles.indexOf("DESKTOP-FEEL (R139)"));
    expect(sheet).toBeLessThan(styles.indexOf("@layer utilities"));
    // The pane's own styles are all still there.
    const pane = build("--styles");
    expect(pane.includes(".fixture-derived")).toBe(false);
    for (const rule of pane
      .replace(/^@layer utilities[\s\S]*$/m, "")
      .match(/^\.[\w-]+\s*\{/gm)
      ?.slice(0, 50) ?? [])
      expect(styles).toContain(rule);
  });

  test("the sheets go in cascade order: desktop.css first, each sheet's @import just before it, Tailwind last", () => {
    const sheets = build("--sheets")
      .split("\n")
      .filter(Boolean)
      .map((file) => path.relative(webviews, file));
    expect(sheets[0]).toBe("src/pages/shared/desktop.css");
    expect(sheets.at(-1)).toBe("src/agent-session/acpmux/tailwind.css");
    expect(new Set(sheets).size).toBe(sheets.length);
    // desktop.ts imports desktop.css, then the glass and the wave (#23995).
    expect(sheets.slice(0, 3)).toEqual(["src/pages/shared/desktop.css", "src/ui/glass/glass.css", "src/ui/wave.css"]);
    // The base layer before the pane's own sheets, the shared popup surface ahead of the menus that wear it.
    const at = (sheet: string) => sheets.indexOf(sheet);
    expect(at("src/agent-session/shared/styles.css")).toBeLessThan(at("src/agent-session/acpmux/styles.css"));
    expect(at("src/ui/popupSurface.css")).toBeLessThan(at("src/agent-session/acpmux/modelPicker.css"));
    expect(at("src/agent-session/acpmux/changes/git.css")).toBe(at("src/agent-session/acpmux/changes/changes.css") - 1);
    // Sheets the pane's modules import come from the bundle (ContextSection.css: 5b32501aeb0).
    expect(sheets).toContain("src/agent-session/acpmux/inspector/ContextSection.css");
    expect(sheets).toContain("src/ui/ghost.css");
  });
});
