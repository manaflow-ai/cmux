// The agent pane's bundle drops CSS: build-agent-pane-web.sh writes the page's one <style> from the
// sheets the dev server's entry imports (bundle.mjs --css-inputs, in import order). A sheet a
// component imports but the page leaves out ships no rules, so in the app the component renders
// unstyled while the dev server (which loads imports) looks right.
// That shipped New Tab's tools without their ghost-button geometry (cx-s6zvc), and the
// Harnesses, Replay and Add Project screens without theirs.
//
// The page is the built resource (CI builds the web bundles before this suite; locally run
// scripts/cmux-next/build-agent-pane-web.sh first).
import { describe, expect, setDefaultTimeout, test } from "bun:test";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";

setDefaultTimeout(180_000);

const webviews = path.resolve(import.meta.dir, "..");
const page = path.resolve(
  webviews,
  "../Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane/index.html",
);
const built = fs.existsSync(page);
if (!built && process.env.CI) throw new Error(`agent-pane-styles: ${page} is not built`);
if (!built) console.warn("agent-pane-styles: skipping (run scripts/cmux-next/build-agent-pane-web.sh)");

/** Trailing spaces are stripped from the page, and a sheet's own @import lines (the page inlines
 * the imported sheet before it), so compare without them. */
const normalize = (css: string) =>
  css
    .replace(/^@import .*\n?/gm, "")
    .replace(/[ \t]+$/gm, "")
    .trim();

describe.skipIf(!built)("agent pane page", () => {
  test("ships the rules of every stylesheet the pane imports", () => {
    const work = fs.mkdtempSync(path.join(os.tmpdir(), "agent-pane-styles-"));
    try {
      const list = path.join(work, "sheets.txt");
      const bundle = spawnSync(
        "bun",
        [
          "scripts/agent-pane/bundle.mjs",
          "src/agent-session/acpmux/main.tsx",
          "src/agent-session/acpmux/shiki",
          path.join(work, "pane/pane.js"),
          "--split",
          "--css-inputs",
          list,
          "--css-inputs-only",
        ],
        { cwd: webviews, encoding: "utf8" },
      );
      expect(bundle.status, bundle.stderr).toBe(0);
      const sheets = fs.readFileSync(list, "utf8").split("\n").filter(Boolean);
      expect(sheets).toContain("src/ui/ghost.css");
      const style = normalize(fs.readFileSync(page, "utf8"));
      const missing = sheets.filter(
        (sheet) => !style.includes(normalize(fs.readFileSync(path.join(webviews, sheet), "utf8"))),
      );
      expect(missing).toEqual([]);
    } finally {
      fs.rmSync(work, { recursive: true, force: true });
    }
  });

  // A sheet's own @import never loads in the page: mid-stylesheet the browser drops it, and the
  // page's CSP loads no style file. changes.css imported git.css that way, so the changes view's
  // Commit, Push and commit form shipped unstyled.
  test("inlines what its sheets @import, and carries no @import of its own", () => {
    const style = normalize(fs.readFileSync(page, "utf8"));
    expect(style.match(/^@import .*$/gm) ?? []).toEqual([]);
    const git = normalize(fs.readFileSync(path.join(webviews, "src/agent-session/acpmux/changes/git.css"), "utf8"));
    expect(style.includes(git)).toBe(true);
  });
});
