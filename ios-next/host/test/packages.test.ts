import { existsSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { defaultHarnesses } from "../src/providers/harnesses.ts";
import { packageBin } from "../src/util.ts";

describe("pinned dependency bins", () => {
  it("resolves ACP adapters and @puppeteer/browsers from node_modules (no npx)", () => {
    for (const [pkg, bin] of [
      ["@agentclientprotocol/claude-agent-acp", "claude-agent-acp"],
      ["@agentclientprotocol/codex-acp", "codex-acp"],
      ["@puppeteer/browsers", undefined],
    ] as const) {
      expect(existsSync(packageBin(pkg, bin))).toBe(true);
    }
    for (const h of defaultHarnesses()) {
      expect(h.command).toBe(process.execPath);
      expect(h.args[0]).toMatch(/node_modules/);
    }
  });
});
