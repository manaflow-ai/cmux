// The agent pane's bundle drops CSS: build-agent-pane-web.sh writes the page's one <style> from a
// list of sheets. A sheet a component imports but the list leaves out ships no rules, so in the
// app the component renders unstyled while the dev server (which loads imports) looks right.
// That shipped New Tab's tools without their ghost-button geometry (cx-s6zvc), and the
// Harnesses, Replay and Add Project screens without theirs. While the list was kept by hand, each
// new import also stopped the page build (ContextSection.css, then ui/wave.css from desktop.ts), and
// with it every fleet app build; the list now comes from the imports (bundle.mjs --css-inputs).
//
// The page is the built resource (CI builds the web bundles before this suite; locally run
// scripts/cmux-next/build-agent-pane-web.sh first).
import { describe, expect, setDefaultTimeout, test } from "bun:test";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { agentPaneStylesheets } from "../dev-server/galleryHost";

setDefaultTimeout(180_000);

const webviews = path.resolve(import.meta.dir, "..");
const page = path.resolve(
  webviews,
  "../Packages/macOS/CmuxNext/Sources/CmuxNextAgentPane/Resources/agent-pane/index.html",
);
const built = fs.existsSync(page);
if (!built && process.env.CI) throw new Error(`agent-pane-styles: ${page} is not built`);
if (!built) console.warn("agent-pane-styles: skipping (run scripts/cmux-next/build-agent-pane-web.sh)");

/** Trailing spaces are stripped from the page, so compare without them. */
const normalize = (css: string) => css.replace(/[ \t]+$/gm, "").trim();

/** bundle.mjs's list of the page's stylesheets, as build-agent-pane-web.sh asks for it. */
let listed: string[] | undefined;
function listedSheets(): string[] {
  if (listed) return listed;
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
        "--page-styles",
        "src/agent-session/acpmux/pageStyles.ts",
        "--css-inputs-only",
      ],
      { cwd: webviews, encoding: "utf8" },
    );
    expect(bundle.status, bundle.stderr).toBe(0);
    listed = fs.readFileSync(list, "utf8").split("\n").filter(Boolean);
    return listed;
  } finally {
    fs.rmSync(work, { recursive: true, force: true });
  }
}

/** Tailwind's entry ships compiled over the pane's sources, not as written. */
const TAILWIND = "src/agent-session/acpmux/tailwind.css";

/** A sheet as the page carries it: its @import of a sibling dropped (the sibling ships ahead of it). */
const shipped = (sheet: string) =>
  normalize(
    fs
      .readFileSync(path.join(webviews, sheet), "utf8")
      .replace(/^[ \t]*@import\s+["']\.\.?\/[^"']+\.css["'];[ \t]*(?:\n|$)/gim, ""),
  );

describe("agent pane stylesheet list", () => {
  test("names every sheet the pane imports, from its own modules and its components'", () => {
    const sheets = listedSheets();
    for (const sheet of [
      "src/pages/shared/desktop.css",
      "src/agent-session/shared/styles.css",
      "src/ui/ghost.css",
      "src/ui/wave.css",
      "src/agent-session/acpmux/inspector/ContextSection.css",
      "src/agent-session/acpmux/changes/git.css",
    ])
      expect(sheets).toContain(sheet);
    expect(new Set(sheets).size).toBe(sheets.length);
  });

  test("keeps the cascade order: pageStyles.ts's sheets first, as the dev server and gallery load them", () => {
    const sheets = listedSheets();
    const at = (sheet: string) => sheets.indexOf(sheet);
    expect(sheets[0]).toBe("src/pages/shared/desktop.css");
    // A sheet's @import comes ahead of it, as a browser applies it.
    expect(at("src/agent-session/acpmux/changes/git.css")).toBe(at("src/agent-session/acpmux/changes/changes.css") - 1);
    const gallery = agentPaneStylesheets()
      .map((file) => path.relative(webviews, file))
      .filter((sheet) => sheet !== TAILWIND);
    expect(sheets.slice(0, gallery.length)).toEqual(gallery);
  });
});

describe.skipIf(!built)("agent pane page", () => {
  test("ships the rules of every stylesheet the pane imports, in the list's order", () => {
    const sheets = listedSheets();
    const style = normalize(fs.readFileSync(page, "utf8"));
    let from = 0;
    const missing: string[] = [];
    for (const sheet of sheets.filter((name) => name !== TAILWIND)) {
      const found = style.indexOf(shipped(sheet), from);
      if (found < 0) missing.push(sheet);
      else from = found;
    }
    expect(missing).toEqual([]);
  });

  // A sheet's own @import never loads in the page: mid-stylesheet the browser drops it, and the
  // page's CSP loads no style file. changes.css imported git.css that way, so the changes view's
  // Commit, Push and commit form shipped unstyled.
  test("inlines what its sheets @import, and carries no @import of its own", () => {
    const style = normalize(fs.readFileSync(page, "utf8"));
    // Outside comments, anywhere on a line, in any case: an indented, conditioned or `@IMPORT` one
    // never loads either.
    expect(style.replace(/\/\*[\s\S]*?\*\//g, "").match(/@import\b.*$/gim) ?? []).toEqual([]);
    const git = normalize(fs.readFileSync(path.join(webviews, "src/agent-session/acpmux/changes/git.css"), "utf8"));
    expect(style.includes(git)).toBe(true);
  });
});
