/**
 * Unit tests for runState (cmux101 state subcommand).
 */
import { describe, it, expect, beforeEach, afterEach } from "bun:test";
import { mkdirSync, rmSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import { runState, formatStateHuman } from "../../../src/cli/state.js";

let tmpDir: string;

beforeEach(() => {
  tmpDir = join(tmpdir(), `cmux101-state-test-${crypto.randomUUID()}`);
  mkdirSync(tmpDir, { recursive: true });
});

afterEach(() => {
  rmSync(tmpDir, { recursive: true, force: true });
});

// ---------------------------------------------------------------------------
// runState
// ---------------------------------------------------------------------------

describe("runState", () => {
  it("returns ok=true and data when worker_state.json exists", async () => {
    const cmuxDir = join(tmpDir, ".cmux101");
    mkdirSync(cmuxDir, { recursive: true });
    const workerState = {
      workerId: "test-worker-id",
      sessionId: "test-session-id",
      providerId: "anthropic",
      model: "claude-sonnet-4-5",
      permissionMode: "default",
      startedAt: "2026-01-01T00:00:00Z",
      cwd: tmpDir,
    };
    await Bun.write(join(cmuxDir, "worker_state.json"), JSON.stringify(workerState, null, 2));

    const result = await runState(tmpDir);
    expect(result.ok).toBe(true);
    expect(result.data).toBeDefined();
    const data = result.data as typeof workerState;
    expect(data.workerId).toBe("test-worker-id");
    expect(data.providerId).toBe("anthropic");
    expect(data.model).toBe("claude-sonnet-4-5");
    expect(result.error).toBeUndefined();
  });

  it("returns ok=false and a helpful error when worker_state.json is missing", async () => {
    // tmpDir has no .cmux101/worker_state.json
    const result = await runState(tmpDir);
    expect(result.ok).toBe(false);
    expect(result.error).toBeDefined();
    expect(result.error).toContain("no worker state file found");
    expect(result.error).toContain(".cmux101/worker_state.json");
    expect(result.error).toContain("cmux101");
    expect(result.data).toBeUndefined();
  });

  it("error message includes helpful hint lines", async () => {
    const result = await runState(tmpDir);
    expect(result.error).toContain("Hint:");
    expect(result.error).toContain("cmux101 -p");
  });
});

// ---------------------------------------------------------------------------
// formatStateHuman
// ---------------------------------------------------------------------------

describe("formatStateHuman", () => {
  it("renders key-value pairs one per line", () => {
    const data = { workerId: "abc", model: "claude-3", cwd: "/tmp/proj" };
    const output = formatStateHuman(data);
    expect(output).toContain("workerId: abc");
    expect(output).toContain("model: claude-3");
    expect(output).toContain("cwd: /tmp/proj");
  });

  it("ends with a newline", () => {
    const output = formatStateHuman({ key: "val" });
    expect(output.endsWith("\n")).toBe(true);
  });
});
