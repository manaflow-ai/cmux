import { describe, expect, test } from "bun:test";
import { mkdtempSync, rmSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { GIT_DEFAULTS, gitDefaultsCommand } from "../scripts/cmux-vm-image/git-defaults";
import { runChild } from "./helpers/run-child";

describe("VM image git defaults (RFD 0065 piece 3)", () => {
  test("lists the five RFD settings", () => {
    expect(Object.fromEntries(GIT_DEFAULTS)).toEqual({
      "checkout.workers": "0",
      "core.untrackedCache": "true",
      "index.version": "4",
      "core.preloadIndex": "true",
      "feature.manyFiles": "true",
    });
  });

  test("the command sets and verifies them in the system file", async () => {
    const dir = mkdtempSync(path.join(os.tmpdir(), "cmux-git-defaults-"));
    try {
      const sys = path.join(dir, "gitconfig");
      const res = await runChild("sh", ["-c", gitDefaultsCommand()], {
        env: { PATH: "/usr/bin:/bin", GIT_CONFIG_SYSTEM: sys, GIT_CONFIG_NOSYSTEM: "", HOME: dir },
        input: "",
      });
      expect(res.stdout).toContain("git-defaults-set");
      const got = await runChild("git", ["config", "--file", sys, "--get", "index.version"], { env: { PATH: "/usr/bin:/bin", HOME: dir }, input: "" });
      expect(got.stdout.trim()).toBe("4");
    } finally {
      rmSync(dir, { recursive: true, force: true });
    }
  });
});
