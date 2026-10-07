import { expect, test } from "bun:test";
import { copyFileSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { join, resolve } from "node:path";
import { spawnSync } from "node:child_process";

const repo = resolve(import.meta.dir, "../..");

test("gallery-only resource strings pass the ownership guard while retired CLI keys remain forbidden", () => {
  const scratch = join(repo, ".cmux-scratch/g5/catalog-ownership");
  mkdirSync(scratch, { recursive: true });
  const fixture = mkdtempSync(join(scratch, "repo-"));
  try {
    expect(spawnSync("git", ["init", "--quiet", fixture]).status).toBe(0);
    mkdirSync(join(fixture, "cmux.xcodeproj"));
    mkdirSync(join(fixture, "Resources"));
    writeFileSync(join(fixture, "cmux.xcodeproj/project.pbxproj"), "// No CLI targets.\n");
    const catalog = join(fixture, "Resources/Localizable.xcstrings");
    copyFileSync(join(repo, "Resources/Localizable.xcstrings"), catalog);
    expect(spawnSync("git", ["-C", fixture, "add", "Resources/Localizable.xcstrings"]).status).toBe(0);
    const check = () =>
      spawnSync("bash", [join(repo, "scripts/cmux-next/check-no-swift-cli.sh"), fixture], { encoding: "utf8" });
    expect(check().status).toBe(0);
    const data = JSON.parse(readFileSync(catalog, "utf8"));
    data.strings["cli.usage"] = data.strings["gallery.experimental"];
    writeFileSync(catalog, JSON.stringify(data));
    expect(check().status).toBe(1);
    writeFileSync(catalog, "invalid json");
    expect(check().status).toBe(1);
    copyFileSync(join(repo, "Resources/Localizable.xcstrings"), catalog);
    mkdirSync(join(fixture, "CLI"));
    writeFileSync(join(fixture, "CLI/main.swift"), "// Retired CLI fixture.\n");
    expect(spawnSync("git", ["-C", fixture, "add", "CLI/main.swift"]).status).toBe(0);
    expect(check().status).toBe(1);
  } finally {
    rmSync(fixture, { recursive: true, force: true });
  }
});
