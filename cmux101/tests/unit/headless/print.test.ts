/**
 * Unit tests for the print output formatter.
 * Tests target `formatEvent` — a pure function — using a fake runner harness.
 */

import { describe, test, expect } from "bun:test";
import { formatEvent, type PrintFormatOpts, type FormattedOutput } from "@/headless/print";
import type { RunnerEvent } from "@/core/runner";

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

function makeState() {
  return { toolNames: new Map<string, string>() };
}

function fmt(event: RunnerEvent, opts: PrintFormatOpts, state = makeState()): FormattedOutput {
  return formatEvent(event, opts, state);
}

/** Simulate a sequence of events and collect combined stderr + stdout. */
function runEvents(events: RunnerEvent[], opts: PrintFormatOpts): { stderr: string; stdout: string } {
  const state = makeState();
  let stderr = "";
  let stdout = "";
  for (const ev of events) {
    const out = formatEvent(ev, opts, state);
    if (out.stderr) stderr += out.stderr;
    if (out.stdout) stdout += out.stdout;
  }
  return { stderr, stdout };
}

// ---------------------------------------------------------------------------
// Fake runner event factories
// ---------------------------------------------------------------------------

function textDelta(text: string): RunnerEvent {
  return { kind: "stream", event: { kind: "text_delta", text } };
}

function toolPre(id: string, name: string, input: unknown = {}): RunnerEvent {
  return { kind: "tool_pre", toolUseId: id, name, input };
}

function toolPost(id: string, content: string, isError = false): RunnerEvent {
  return { kind: "tool_post", toolUseId: id, result: { content, isError }, isError };
}

function turnEnd(): RunnerEvent {
  return { kind: "turn_end", reason: "end_turn" };
}

function errorEvent(msg: string): RunnerEvent {
  return { kind: "error", error: new Error(msg) };
}

// ---------------------------------------------------------------------------
// Text mode: tool result summaries
// ---------------------------------------------------------------------------

describe("text mode – tool result summaries", () => {
  test("non-error result shows [result] prefix with first 300 chars", () => {
    const state = makeState();
    const opts: PrintFormatOpts = { verbose: false, quiet: false, outputFormat: "text" };
    const long = "x".repeat(400);

    fmt(toolPre("1", "file_read"), opts, state); // register name
    const out = fmt(toolPost("1", long), opts, state);

    expect(out.stderr).toContain("[result]");
    // truncated to 300 + ellipsis
    expect(out.stderr).toContain("x".repeat(300));
    expect(out.stderr!.length).toBeLessThan(long.length + 50);
  });

  test("error result shows full content without truncation", () => {
    const state = makeState();
    const opts: PrintFormatOpts = { verbose: false, quiet: false, outputFormat: "text" };
    const errMsg = "E".repeat(500);

    fmt(toolPre("2", "shell"), opts, state);
    const out = fmt(toolPost("2", errMsg, true), opts, state);

    expect(out.stderr).toContain(errMsg);
    expect(out.stderr).toContain("[tool ✗]");
  });

  test("verbose mode shows full content", () => {
    const state = makeState();
    const opts: PrintFormatOpts = { verbose: true, quiet: false, outputFormat: "text" };
    const content = "line\n".repeat(100);

    fmt(toolPre("3", "file_read"), opts, state);
    const out = fmt(toolPost("3", content), opts, state);

    expect(out.stderr).toContain(content);
  });

  test("[tool ✓] status line appears on success", () => {
    const state = makeState();
    const opts: PrintFormatOpts = { outputFormat: "text" };

    fmt(toolPre("4", "grep"), opts, state);
    const out = fmt(toolPost("4", "match found"), opts, state);

    expect(out.stderr).toContain("[tool ✓]");
    expect(out.stderr).toContain("[result]");
  });
});

// ---------------------------------------------------------------------------
// Text mode: file_edit diff rendering
// ---------------------------------------------------------------------------

describe("text mode – file_edit diff rendering", () => {
  const unifiedDiff = `--- a/foo.ts\n+++ b/foo.ts\n@@ -1,3 +1,3 @@\n-old line\n+new line\n context`;

  test("unified diff content is detected and passed through (no color, no TTY)", () => {
    const state = makeState();
    const opts: PrintFormatOpts = { outputFormat: "text", isTTY: false };

    fmt(toolPre("5", "file_edit"), opts, state);
    const out = fmt(toolPost("5", unifiedDiff), opts, state);

    expect(out.stderr).toContain("-old line");
    expect(out.stderr).toContain("+new line");
    // Not truncated to 300 chars
    expect(out.stderr).toContain("--- a/foo.ts");
  });

  test("diff with TTY=true wraps + lines in green, - lines in red", () => {
    const state = makeState();
    const opts: PrintFormatOpts = { outputFormat: "text", isTTY: true };

    fmt(toolPre("6", "file_edit"), opts, state);
    const out = fmt(toolPost("6", unifiedDiff), opts, state);

    // Green for added lines
    expect(out.stderr).toContain("\x1b[32m+new line\x1b[0m");
    // Red for removed lines
    expect(out.stderr).toContain("\x1b[31m-old line\x1b[0m");
    // +++ and --- headers stay uncolored
    expect(out.stderr).toContain("--- a/foo.ts");
    expect(out.stderr).toContain("+++ b/foo.ts");
  });

  test("Index: prefix also triggers diff rendering", () => {
    const indexDiff = `Index: src/foo.ts\n===\n--- src/foo.ts\n+++ src/foo.ts\n-a\n+b`;
    const state = makeState();
    const opts: PrintFormatOpts = { outputFormat: "text", isTTY: false };

    fmt(toolPre("7", "str_replace_editor"), opts, state);
    const out = fmt(toolPost("7", indexDiff), opts, state);

    expect(out.stderr).toContain("Index: src/foo.ts");
  });
});

// ---------------------------------------------------------------------------
// Text mode: shell compact rendering
// ---------------------------------------------------------------------------

describe("text mode – shell compact rendering", () => {
  test("shell result shows exit code line + first 20 lines", () => {
    const lines = Array.from({ length: 30 }, (_, i) => `line ${i + 1}`);
    const content = `Exit code: 0\n${lines.join("\n")}`;
    const state = makeState();
    const opts: PrintFormatOpts = { outputFormat: "text" };

    fmt(toolPre("8", "shell"), opts, state);
    const out = fmt(toolPost("8", content), opts, state);

    expect(out.stderr).toContain("Exit code: 0");
    expect(out.stderr).toContain("line 1");
    expect(out.stderr).not.toContain("line 30");
    expect(out.stderr).toContain("more lines");
  });
});

// ---------------------------------------------------------------------------
// Text mode: multiline tools (first 20 lines)
// ---------------------------------------------------------------------------

describe("text mode – multiline tool rendering", () => {
  for (const toolName of ["cmux_tree", "cmux_read_screen", "file_read", "grep", "glob"]) {
    test(`${toolName} shows first 20 lines`, () => {
      const lines = Array.from({ length: 50 }, (_, i) => `line ${i + 1}`);
      const content = lines.join("\n");
      const state = makeState();
      const opts: PrintFormatOpts = { outputFormat: "text" };

      fmt(toolPre("9", toolName), opts, state);
      const out = fmt(toolPost("9", content), opts, state);

      expect(out.stderr).toContain("line 1");
      expect(out.stderr).toContain("line 20");
      expect(out.stderr).not.toContain("line 21");
      expect(out.stderr).toContain("more lines");
    });
  }
});

// ---------------------------------------------------------------------------
// --quiet flag
// ---------------------------------------------------------------------------

describe("--quiet suppresses tool output", () => {
  test("quiet mode: no tool pre/post/result output on stderr", () => {
    const events: RunnerEvent[] = [
      toolPre("q1", "shell"),
      toolPost("q1", "some output"),
    ];
    const { stderr, stdout } = runEvents(events, { quiet: true, outputFormat: "text" });
    expect(stderr).toBe("");
    expect(stdout).toBe("");
  });

  test("quiet mode: assistant text still written to stdout", () => {
    const events: RunnerEvent[] = [
      toolPre("q2", "shell"),
      toolPost("q2", "some output"),
      textDelta("Hello!"),
      turnEnd(),
    ];
    const { stderr, stdout } = runEvents(events, { quiet: true, outputFormat: "text" });
    expect(stderr).toBe("");
    expect(stdout).toContain("Hello!");
  });

  test("quiet mode: errors still appear on stderr", () => {
    const events: RunnerEvent[] = [errorEvent("boom")];
    const { stderr } = runEvents(events, { quiet: true, outputFormat: "text" });
    expect(stderr).toContain("[error] boom");
  });
});

// ---------------------------------------------------------------------------
// JSON / NDJSON mode
// ---------------------------------------------------------------------------

describe("JSON mode emits NDJSON", () => {
  function parseLines(s: string): unknown[] {
    return s
      .split("\n")
      .filter((l) => l.trim())
      .map((l) => JSON.parse(l));
  }

  test("text_delta emits {kind: 'text_delta', text}", () => {
    const out = fmt(textDelta("hello"), { outputFormat: "json" });
    const obj = JSON.parse(out.stdout!);
    expect(obj).toEqual({ kind: "text_delta", text: "hello" });
  });

  test("tool_pre emits {kind: 'tool_call', name, input, id}", () => {
    const state = makeState();
    const out = fmt(toolPre("t1", "file_read", { path: "x.ts" }), { outputFormat: "json" }, state);
    const obj = JSON.parse(out.stdout!);
    expect(obj.kind).toBe("tool_call");
    expect(obj.name).toBe("file_read");
    expect(obj.id).toBe("t1");
    expect(obj.input).toEqual({ path: "x.ts" });
  });

  test("tool_post emits {kind: 'tool_result', id, content, isError}", () => {
    const state = makeState();
    fmt(toolPre("t2", "grep"), { outputFormat: "json" }, state); // register name
    const out = fmt(toolPost("t2", "match", false), { outputFormat: "json" }, state);
    const obj = JSON.parse(out.stdout!);
    expect(obj.kind).toBe("tool_result");
    expect(obj.id).toBe("t2");
    expect(obj.content).toBe("match");
    expect(obj.isError).toBe(false);
  });

  test("turn_end emits {kind: 'turn_end', reason}", () => {
    const out = fmt(turnEnd(), { outputFormat: "json" });
    const obj = JSON.parse(out.stdout!);
    expect(obj.kind).toBe("turn_end");
    expect(obj.reason).toBe("end_turn");
  });

  test("full session emits valid NDJSON for each event", () => {
    const events: RunnerEvent[] = [
      toolPre("j1", "shell", { cmd: "ls" }),
      toolPost("j1", "file1\nfile2"),
      textDelta("Done."),
      turnEnd(),
    ];
    const { stdout } = runEvents(events, { outputFormat: "json" });
    const objs = parseLines(stdout);
    expect(objs).toHaveLength(4);
    expect((objs[0] as Record<string, unknown>).kind).toBe("tool_call");
    expect((objs[1] as Record<string, unknown>).kind).toBe("tool_result");
    expect((objs[2] as Record<string, unknown>).kind).toBe("text_delta");
    expect((objs[3] as Record<string, unknown>).kind).toBe("turn_end");
  });

  test("stderr is empty in JSON mode for normal events", () => {
    const events: RunnerEvent[] = [
      toolPre("j2", "file_read"),
      toolPost("j2", "content"),
    ];
    const { stderr } = runEvents(events, { outputFormat: "json" });
    expect(stderr).toBe("");
  });
});
