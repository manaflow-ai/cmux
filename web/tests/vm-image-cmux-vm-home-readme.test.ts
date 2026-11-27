import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import path from "node:path";
import { HOME_README, HOME_README_PATH, homeReadmeFile } from "../scripts/cmux-vm-image/home-readme";

describe("the Cloud machine's ~/README.md", () => {
  test("sits in the work user's home and says how to see and ask for more", () => {
    expect(HOME_README_PATH).toBe("/home/cmux/README.md");
    expect(homeReadmeFile()).toEqual({ path: HOME_README_PATH, text: HOME_README, mode: 0o644 });
    expect(HOME_README).toContain("cmux capabilities");
    expect(HOME_README).toContain("no token");
    expect(HOME_README).toContain("cmux machine request --vcpu N --mem M");
  });

  test("carries no sizes or prices, so it cannot drift from `cmux capabilities`", () => {
    expect(HOME_README).not.toMatch(/\$\d|\d+ ?vCPU|\d+ ?GB/);
  });

  test("the bake writes it", () => {
    const bake = readFileSync(path.join(import.meta.dir, "../scripts/cmux-vm-image/bake.ts"), "utf8");
    expect(bake).toContain("homeReadmeFile()");
  });
});
