import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import test from "node:test";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const source = fs.readFileSync(path.join(root, "scripts/reload.sh"), "utf8");

test("reload stamps the completed app before signing it", () => {
  const invocation = source.indexOf('\nreload_stamp_source_revision "$APP_PATH" "$SCRIPT_DIR/.."');
  assert.ok(invocation > source.indexOf('validate_app_bundle "$APP_PATH" "$APP_EXECUTABLE_NAME"'));
  assert.ok(invocation < source.indexOf('if ! /usr/bin/codesign --force --sign -'));
});

test("missing and stale bundled revision stamps are replaced from the source checkout", {
  skip: process.platform !== "darwin",
}, () => {
  const start = source.indexOf("reload_stamp_source_revision() {");
  assert.ok(start >= 0);
  const end = source.indexOf("\n}\n", start);
  const helper = source.slice(start, end + 2);
  const temporary = fs.mkdtempSync(path.join(os.tmpdir(), "cmux-revision-test-"));
  try {
    const app = path.join(temporary, "cmux DEV fixture.app");
    fs.mkdirSync(path.join(app, "Contents"), { recursive: true });
    const plist = path.join(app, "Contents/Info.plist");
    fs.writeFileSync(plist, '<?xml version="1.0"?><plist version="1.0"><dict><key>CFBundleName</key><string>fixture</string></dict></plist>');
    const expected = spawnSync("git", ["-C", root, "rev-parse", "--short=10", "HEAD"], { encoding: "utf8" }).stdout.trim();
    for (const stale of [false, true]) {
      if (stale) spawnSync("/usr/libexec/PlistBuddy", ["-c", "Set :CMUXCommit deadbeef00", plist]);
      const result = spawnSync("bash", ["-c", `${helper}\nreload_stamp_source_revision "$1" "$2"`, "test", app, root], {
        encoding: "utf8", env: { ...process.env, GIT_DIR: "/nonexistent/foreign-git-dir" },
      });
      assert.equal(result.status, 0, result.stderr);
      const actual = spawnSync("/usr/libexec/PlistBuddy", ["-c", "Print :CMUXCommit", plist], { encoding: "utf8" });
      assert.equal(actual.stdout.trim(), expected);
    }
  } finally {
    fs.rmSync(temporary, { recursive: true, force: true });
  }
});
