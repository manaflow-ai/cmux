/**
 * Unit tests for power slash commands (/ultraplan, /teleport, /bughunter).
 */
import { describe, it, expect } from "bun:test";
import { createPowerCommands } from "../../../src/cli/power_commands.js";
import type { SlashContext } from "../../../src/cli/slash.js";

// ---------------------------------------------------------------------------
// Minimal mock context (power commands don't use ctx)
// ---------------------------------------------------------------------------

const mockCtx = {} as SlashContext;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function getCommand(name: string) {
  const cmds = createPowerCommands();
  const cmd = cmds.find((c) => c.name === name);
  if (!cmd) throw new Error(`Command /${name} not found`);
  return cmd;
}

// ---------------------------------------------------------------------------
// /ultraplan
// ---------------------------------------------------------------------------

describe("/ultraplan", () => {
  it("returns consumed=true", async () => {
    const cmd = getCommand("ultraplan");
    const result = await cmd.run(mockCtx, "build a REST API");
    expect(result.consumed).toBe(true);
  });

  it("includes the user input in the transformedPrompt", async () => {
    const cmd = getCommand("ultraplan");
    const input = "build a REST API with authentication";
    const result = await cmd.run(mockCtx, input);
    expect(result.transformedPrompt).toBeDefined();
    expect(result.transformedPrompt).toContain(input);
  });

  it("includes planning mode instructions in the transformedPrompt", async () => {
    const cmd = getCommand("ultraplan");
    const result = await cmd.run(mockCtx, "some topic");
    expect(result.transformedPrompt).toContain("deep-planning mode");
    expect(result.transformedPrompt).toContain("Do not actually execute any tools yet");
  });

  it("handles empty args gracefully", async () => {
    const cmd = getCommand("ultraplan");
    const result = await cmd.run(mockCtx, "");
    expect(result.consumed).toBe(true);
    expect(result.transformedPrompt).toBeDefined();
  });
});

// ---------------------------------------------------------------------------
// /teleport
// ---------------------------------------------------------------------------

describe("/teleport", () => {
  it("returns consumed=true", async () => {
    const cmd = getCommand("teleport");
    const result = await cmd.run(mockCtx, "src/cli/slash.ts");
    expect(result.consumed).toBe(true);
  });

  it("embeds the target in the transformedPrompt", async () => {
    const cmd = getCommand("teleport");
    const target = "SlashRegistry";
    const result = await cmd.run(mockCtx, target);
    expect(result.transformedPrompt).toBeDefined();
    expect(result.transformedPrompt).toContain(target);
  });

  it("includes codebase search instructions", async () => {
    const cmd = getCommand("teleport");
    const result = await cmd.run(mockCtx, "app.tsx");
    expect(result.transformedPrompt).toContain("glob");
    expect(result.transformedPrompt).toContain("grep");
  });
});

// ---------------------------------------------------------------------------
// /bughunter
// ---------------------------------------------------------------------------

describe("/bughunter", () => {
  it("defaults to 'current directory' when no args provided", async () => {
    const cmd = getCommand("bughunter");
    const result = await cmd.run(mockCtx, "");
    expect(result.consumed).toBe(true);
    expect(result.transformedPrompt).toContain("current directory");
  });

  it("embeds the scope when provided", async () => {
    const cmd = getCommand("bughunter");
    const scope = "src/cli";
    const result = await cmd.run(mockCtx, scope);
    expect(result.transformedPrompt).toBeDefined();
    expect(result.transformedPrompt).toContain(scope);
  });

  it("includes anti-pattern scanning instructions", async () => {
    const cmd = getCommand("bughunter");
    const result = await cmd.run(mockCtx, "src");
    expect(result.transformedPrompt).toContain("TODO");
    expect(result.transformedPrompt).toContain("grep");
  });

  it("returns consumed=true", async () => {
    const cmd = getCommand("bughunter");
    const result = await cmd.run(mockCtx, "src");
    expect(result.consumed).toBe(true);
  });
});
