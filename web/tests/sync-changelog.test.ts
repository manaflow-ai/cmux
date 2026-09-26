import { expect, test } from "bun:test";
import { execFileSync } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const syncScript = fileURLToPath(
  new URL("../tools/sync-changelog.ts", import.meta.url),
);

test("copies the repository changelog into the web project", () => {
  const directory = mkdtempSync(join(tmpdir(), "sync-changelog-"));
  try {
    const source = join(directory, "CHANGELOG.md");
    const destination = join(directory, "web", "CHANGELOG.md");
    writeFileSync(source, "## 1.2.3\n\n- Release note\n");

    execFileSync("bun", [syncScript, source, destination], {
      encoding: "utf8",
    });

    expect(readFileSync(destination, "utf8")).toBe(readFileSync(source, "utf8"));
  } finally {
    rmSync(directory, { recursive: true, force: true });
  }
});
