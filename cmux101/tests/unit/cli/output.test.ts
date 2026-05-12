import { describe, test, expect, spyOn, beforeEach, afterEach } from "bun:test";
import { shouldOutputJson, emit } from "@/cli/output";
import type { ParsedArgs } from "@/cli/args";

// ---------------------------------------------------------------------------
// shouldOutputJson
// ---------------------------------------------------------------------------

describe("shouldOutputJson", () => {
  test("returns false when outputFormat is undefined", () => {
    const parsed: ParsedArgs = { mode: "tui" };
    expect(shouldOutputJson(parsed)).toBe(false);
  });

  test("returns false when outputFormat is 'text'", () => {
    const parsed: ParsedArgs = { mode: "tui", outputFormat: "text" };
    expect(shouldOutputJson(parsed)).toBe(false);
  });

  test("returns true when outputFormat is 'json'", () => {
    const parsed: ParsedArgs = { mode: "doctor", outputFormat: "json" };
    expect(shouldOutputJson(parsed)).toBe(true);
  });
});

// ---------------------------------------------------------------------------
// emit
// ---------------------------------------------------------------------------

describe("emit", () => {
  let written: string[] = [];
  let origWrite: typeof process.stdout.write;

  beforeEach(() => {
    written = [];
    origWrite = process.stdout.write.bind(process.stdout);
    // @ts-ignore — override for testing
    process.stdout.write = (chunk: unknown) => {
      written.push(String(chunk));
      return true;
    };
  });

  afterEach(() => {
    // @ts-ignore
    process.stdout.write = origWrite;
  });

  test("JSON mode writes JSON.stringify output", () => {
    const parsed: ParsedArgs = { mode: "doctor", outputFormat: "json" };
    const data = { ok: true, checks: [] };
    emit(parsed, data, () => "text-render");
    expect(written.join("")).toBe(JSON.stringify(data, null, 2) + "\n");
  });

  test("text mode calls textRender", () => {
    const parsed: ParsedArgs = { mode: "doctor", outputFormat: "text" };
    const data = { ok: true, checks: [] };
    emit(parsed, data, () => "my-text-output");
    expect(written.join("")).toBe("my-text-output");
  });

  test("text mode is default when outputFormat undefined", () => {
    const parsed: ParsedArgs = { mode: "tui" };
    emit(parsed, 42, () => "rendered-42");
    expect(written.join("")).toBe("rendered-42");
  });

  test("JSON mode: nested objects are serialized", () => {
    const parsed: ParsedArgs = { mode: "sessions", outputFormat: "json" };
    const data = [{ id: "abc", model: "claude" }];
    emit(parsed, data, () => "ignored");
    const parsed2 = JSON.parse(written.join(""));
    expect(parsed2).toEqual(data);
  });
});
