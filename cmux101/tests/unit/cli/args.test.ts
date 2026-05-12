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

  // --output-format
  test("--output-format json sets outputFormat", () => {
    const r = parseArgs(["--output-format", "json"]);
    expect(r.outputFormat).toBe("json");
  });

  test("--output-format text sets outputFormat", () => {
    const r = parseArgs(["--output-format", "text"]);
    expect(r.outputFormat).toBe("text");
  });

  test("--output-format invalid value throws", () => {
    expect(() => parseArgs(["--output-format", "xml"])).toThrow();
  });

  test("outputFormat defaults to undefined when not passed", () => {
    const r = parseArgs([]);
    expect(r.outputFormat).toBeUndefined();
  });

  // doctor subcommand
  test("doctor subcommand sets mode to doctor", () => {
    const r = parseArgs(["doctor"]);
    expect(r.mode).toBe("doctor");
  });

  test("doctor with --output-format json", () => {
    const r = parseArgs(["doctor", "--output-format", "json"]);
    expect(r.mode).toBe("doctor");
    expect(r.outputFormat).toBe("json");
  });

  // sessions subcommand
  test("sessions subcommand sets mode to sessions", () => {
    const r = parseArgs(["sessions"]);
    expect(r.mode).toBe("sessions");
  });

  test("sessions with --output-format json", () => {
    const r = parseArgs(["--output-format", "json", "sessions"]);
    expect(r.mode).toBe("sessions");
    expect(r.outputFormat).toBe("json");
  });

  // --allowedTools
  test('--allowedTools "file_read,glob" parses to ["file_read", "glob"]', () => {
    const r = parseArgs(["--allowedTools", "file_read,glob"]);
    expect(r.allowedTools).toEqual(["file_read", "glob"]);
  });

  test("--allowedTools with spaces around commas is trimmed", () => {
    const r = parseArgs(["--allowedTools", "file_read , glob , grep"]);
    expect(r.allowedTools).toEqual(["file_read", "glob", "grep"]);
  });

  test("--allowedTools single tool", () => {
    const r = parseArgs(["--allowedTools", "bash"]);
    expect(r.allowedTools).toEqual(["bash"]);
  });

  test("allowedTools defaults to undefined when not passed", () => {
    const r = parseArgs([]);
    expect(r.allowedTools).toBeUndefined();
  });

  // state subcommand
  test("state subcommand sets mode to state", () => {
    const r = parseArgs(["state"]);
    expect(r.mode).toBe("state");
  });

  test("state with --output-format json", () => {
    const r = parseArgs(["state", "--output-format", "json"]);
    expect(r.mode).toBe("state");
    expect(r.outputFormat).toBe("json");
  });
});
