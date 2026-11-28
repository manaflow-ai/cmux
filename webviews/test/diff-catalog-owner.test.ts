import { expect, test } from "bun:test";
import { copyFileSync, cpSync, mkdirSync, mkdtempSync, rmSync, statSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { spawnSync } from "node:child_process";
import { PAGES } from "../scripts/pages/gen-strings.mjs";

const repo = resolve(import.meta.dir, "../..");

test("the diff generator's catalog inputs pass the no-Swift-CLI ownership guard", () => {
  const scratch = join(repo, ".cmux-scratch/diff-catalog-owner");
  mkdirSync(scratch, { recursive: true });
  const fixture = mkdtempSync(join(scratch, "catalog-"));
  try {
    expect(spawnSync("git", ["init", "--quiet", fixture]).status).toBe(0);
    mkdirSync(join(fixture, "cmux.xcodeproj"));
    writeFileSync(join(fixture, "cmux.xcodeproj/project.pbxproj"), "// Catalog ownership fixture; no targets.\n");
    for (const { file } of PAGES.diff.catalogs) {
      const target = join(fixture, file);
      mkdirSync(dirname(target), { recursive: true });
      // A catalog may be a directory of one file per key (`Localizable.xcstrings.d`, #56351).
      if (statSync(join(repo, file)).isDirectory()) cpSync(join(repo, file), target, { recursive: true });
      else copyFileSync(join(repo, file), target);
      expect(spawnSync("git", ["-C", fixture, "add", "--", file]).status).toBe(0);
    }
    const result = spawnSync("bash", [join(repo, "scripts/cmux-next/check-no-swift-cli.sh"), fixture], {
      encoding: "utf8",
    });
    expect({ status: result.status, stderr: result.stderr }).toEqual({ status: 0, stderr: "" });
  } finally {
    rmSync(fixture, { recursive: true, force: true });
  }
  // Copying and adding a catalog of one file per key (4,000 files) runs past bun's 5 s default.
}, 60_000);
