import { describe, test, expect } from "bun:test";
import { parseArgs } from "@/cli/args";

describe("parseArgs", () => {
  test("no args → tui mode", () => {
    const r = parseArgs([]);
    expect(r.mode).toBe("tui");
    expect(r.prompt).toBeUndefined();
  });

  test('-p "hello" → print mode with prompt', () => {
    const r = parseArgs(["-p", "hello"]);
    expect(r.mode).toBe("print");
    expect(r.print).toBe(true);
    expect(r.prompt).toBe("hello");
  });

  test("--print with prompt", () => {
    const r = parseArgs(["--print", "do the thing"]);
    expect(r.mode).toBe("print");
    expect(r.prompt).toBe("do the thing");
  });

  test("--model and --provider with positional prompt", () => {
    const r = parseArgs(["--model", "claude-opus-4-7", "--provider", "anthropic", "do thing"]);
    expect(r.model).toBe("claude-opus-4-7");
    expect(r.provider).toBe("anthropic");
    expect(r.prompt).toBe("do thing");
    expect(r.mode).toBe("tui");
  });

  test("auth login openai", () => {
    const r = parseArgs(["auth", "login", "openai"]);
    expect(r.mode).toBe("auth");
    expect(r.authSubcommand?.action).toBe("login");
    expect(r.authSubcommand?.provider).toBe("openai");
  });

  test("auth logout anthropic", () => {
    const r = parseArgs(["auth", "logout", "anthropic"]);
    expect(r.mode).toBe("auth");
    expect(r.authSubcommand?.action).toBe("logout");
    expect(r.authSubcommand?.provider).toBe("anthropic");
  });

  test("models openrouter", () => {
    const r = parseArgs(["models", "openrouter"]);
    expect(r.mode).toBe("models");
    expect(r.provider).toBe("openrouter");
  });

  test("models (no provider)", () => {
    const r = parseArgs(["models"]);
    expect(r.mode).toBe("models");
    expect(r.provider).toBeUndefined();
  });

  test("--help flag", () => {
    const r = parseArgs(["--help"]);
    expect(r.mode).toBe("help");
  });

  test("-h flag", () => {
    const r = parseArgs(["-h"]);
    expect(r.mode).toBe("help");
  });

  test("--version flag", () => {
    const r = parseArgs(["--version"]);
    expect(r.mode).toBe("version");
  });

  test("-v flag", () => {
    const r = parseArgs(["-v"]);
    expect(r.mode).toBe("version");
  });

  test("--show-thinking flag", () => {
    const r = parseArgs(["--show-thinking"]);
    expect(r.showThinking).toBe(true);
  });

  test("--auto sets permissionMode", () => {
    const r = parseArgs(["--auto"]);
    expect(r.permissionMode).toBe("auto");
  });

  test("--plan sets permissionMode", () => {
    const r = parseArgs(["--plan"]);
    expect(r.permissionMode).toBe("plan");
  });

  test("--resume sets resume id", () => {
    const r = parseArgs(["--resume", "abc-123"]);
    expect(r.resume).toBe("abc-123");
  });

  test("--cwd sets cwd", () => {
    const r = parseArgs(["--cwd", "/tmp/project"]);
    expect(r.cwd).toBe("/tmp/project");
  });

  test("multi-word positional joined as prompt", () => {
    const r = parseArgs(["fix", "the", "bug"]);
    expect(r.prompt).toBe("fix the bug");
    expect(r.mode).toBe("tui");
  });

  test("unknown flag throws", () => {
    expect(() => parseArgs(["--unknown-flag"])).toThrow();
  });

  test("auth login missing provider throws", () => {
    expect(() => parseArgs(["auth", "login"])).toThrow();
  });
});
