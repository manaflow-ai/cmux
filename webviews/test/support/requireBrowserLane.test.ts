import { describe, expect, test } from "bun:test";
import { requireBrowserLane } from "./requireBrowserLane";

const message = "browser test skipped: runs only in CI or on a Freestyle VM (set CMUX_BROWSER_TESTS=1 there)";

describe("requireBrowserLane", () => {
  for (const env of [
    {},
    { CI: "false" },
    { CI: "1" },
    { CI: "TRUE" },
    { CMUX_BROWSER_TESTS: "true" },
    { CI: "false", CMUX_BROWSER_TESTS: "0" },
  ]) {
    test(`skips all module setup without an authorized lane: ${JSON.stringify(env)}`, async () => {
      let probes = 0;
      const lines: string[] = [];
      const skipped: string[] = [];
      await requireBrowserLane(
        "synthetic browser file",
        () => {
          probes += 1;
        },
        {
          env,
          report: (line) => {
            lines.push(line);
          },
          skip: (name) => {
            skipped.push(name);
          },
        },
      );
      expect(probes).toBe(0);
      expect(lines).toEqual([message]);
      expect(skipped).toEqual(["synthetic browser file"]);
    });
  }

  for (const env of [{ CI: "true" }, { CMUX_BROWSER_TESTS: "1" }, { CI: "false", CMUX_BROWSER_TESTS: "1" }]) {
    test(`awaits module registration in an authorized lane: ${JSON.stringify(env)}`, async () => {
      let registered = false;
      const lines: string[] = [];
      const skipped: string[] = [];
      await requireBrowserLane(
        "synthetic browser file",
        async () => {
          await Promise.resolve();
          registered = true;
        },
        {
          env,
          report: (line) => {
            lines.push(line);
          },
          skip: (name) => {
            skipped.push(name);
          },
        },
      );
      expect(registered).toBe(true);
      expect(lines).toEqual([]);
      expect(skipped).toEqual([]);
    });
  }

  test("propagates registration failures in an authorized lane", async () => {
    await expect(
      requireBrowserLane(
        "failure",
        async () => {
          throw new Error("registration failed");
        },
        { env: { CI: "true" } },
      ),
    ).rejects.toThrow("registration failed");
  });
});
