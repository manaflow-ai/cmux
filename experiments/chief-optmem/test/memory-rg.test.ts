import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, it } from "vite-plus/test";
import { parseRg, rg, type RgQuery } from "../src/memory/rg.ts";
import { utf8Length } from "../src/memory/text.ts";

const LOG = [
  "#0 2026-10-01 Lawrence prefers dark mode",
  "#1 2026-10-01 spawned worker deploy-fix on the mini",
  "#2 2026-10-01 worker deploy-fix: PR merged",
  "#3 2026-10-02 lawrence asked about the café invoice",
  "#4 2026-10-02 deploy failed on staging, retry tomorrow",
  "#5 2026-10-02 unrelated note",
  "#6 2026-10-02 another unrelated note",
  "#7 2026-10-03 Deploy succeeded; 日本 team notified",
  "#8 2026-10-03 a.c is not abc",
];

const query = (args: Array<string>): RgQuery => {
  const q = parseRg(args);
  if ("error" in q) throw new Error(`parse failed for ${args.join(" ")}`);
  return q;
};

const search = (args: Array<string>) => rg(LOG, query(args), 1 << 20, utf8Length).lines;

const CASES: Array<Array<string>> = [
  ["deploy"],
  ["Deploy"],
  ["-i", "Deploy"],
  ["-s", "deploy"],
  ["lawrence"],
  ["-F", "a.c"],
  ["a.c"],
  ["-w", "note"],
  ["-w", "deploy"],
  ["-C1", "merged"],
  ["-A", "1", "deploy"],
  ["-B2", "Deploy"],
  ["-C", "1", "-i", "unrelated"],
  ["café|日本"],
  ["--", "-fix"],
];

describe("rg-style memory search", () => {
  const hasRg = (() => {
    try {
      execFileSync("rg", ["--version"]);
      return true;
    } catch {
      return false;
    }
  })();

  it.skipIf(!hasRg)("prints what ripgrep prints for the same log and flags", () => {
    const dir = mkdtempSync(join(tmpdir(), "chief-rg-"));
    const file = join(dir, "LOG.txt");
    writeFileSync(file, `${LOG.join("\n")}\n`);
    for (const args of CASES) {
      let expected = "";
      try {
        expected = execFileSync("rg", ["--no-filename", "--no-line-number", "--color=never", "-S", ...args, file], {
          encoding: "utf8",
        });
      } catch (e) {
        expected = (e as { stdout?: string }).stdout ?? "";
      }
      const got = search(args);
      expect({ args, out: got.length ? `${got.join("\n")}\n` : "" }).toEqual({ args, out: expected });
    }
  });

  it("keeps the newest output within the cap and counts every hit", () => {
    const found = rg(LOG, query(["deploy"]), 90, utf8Length);
    expect(found.hits).toBe(4);
    expect(found.lines).toEqual(["#7 2026-10-03 Deploy succeeded; 日本 team notified"]);
    expect(found.shown).toBe(1);
  });

  it("refuses unknown flags and missing patterns", () => {
    expect(parseRg(["-x", "a"])).toEqual({ error: "usage" });
    expect(parseRg([])).toEqual({ error: "usage" });
    expect(parseRg(["a", "b"])).toEqual({ error: "usage" });
    expect(parseRg(["-C", "x", "a"])).toEqual({ error: "usage" });
  });
});
