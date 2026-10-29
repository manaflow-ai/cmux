// Read the same CSS import graph as build-agent-pane-web.sh: dev.tsx's base sheets, then the
// component sheets it reaches, in cascade order. Keep the bundler as the owner of that order.
// Repo paths ("webviews/src/..."), as before: the bundler lists them relative to webviews/.
import { spawnSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";

const WEBVIEWS = path.resolve(import.meta.dir, "../..");
const REPO = path.resolve(WEBVIEWS, "..");
let cached: string[] | undefined;

export function paneSheets(): string[] {
  if (cached) return [...cached];
  const work = mkdtempSync(path.join(tmpdir(), "cmux-pane-sheets-"));
  try {
    const list = path.join(work, "sheets.txt");
    const bundle = spawnSync(
      "bun",
      [
        "scripts/agent-pane/bundle.mjs",
        "src/agent-session/acpmux/dev.tsx",
        "src/agent-session/acpmux/shiki",
        path.join(work, "pane/pane.js"),
        "--split",
        "--css-inputs",
        list,
        "--css-inputs-only",
      ],
      { cwd: WEBVIEWS, encoding: "utf8", timeout: 60_000 },
    );
    if (bundle.error) throw bundle.error;
    if (bundle.status !== 0) throw new Error(`pane stylesheet graph failed (${bundle.status}): ${bundle.stderr}`);
    const sheets = readFileSync(list, "utf8")
      .split("\n")
      .filter(Boolean)
      .map((sheet) => path.relative(REPO, path.resolve(WEBVIEWS, sheet)));
    if (sheets.length === 0) throw new Error("pane stylesheet graph returned no styles");
    cached = sheets;
    return [...cached];
  } finally {
    rmSync(work, { recursive: true, force: true });
  }
}
