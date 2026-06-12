import { describe, expect, test } from "bun:test";
import {
  clampTextLines,
  commandExecutionView,
  computeLineDiff,
  fileChangeDiffs,
  fileViewData,
  formatDurationSeconds,
  parseApplyPatch,
  webSearchView,
  type DiffLine,
} from "./toolData";

function kinds(lines: DiffLine[]): string[] {
  return lines.map((line) => line.kind);
}

describe("computeLineDiff", () => {
  test("single-line replacement is a del/add pair", () => {
    const lines = computeLineDiff("const a = 1;", "const a = 2;");
    expect(lines).toEqual([
      { kind: "del", text: "const a = 1;" },
      { kind: "add", text: "const a = 2;" },
    ]);
  });

  test("keeps shared prefix/suffix lines as context", () => {
    const lines = computeLineDiff("keep\nold middle\ntail", "keep\nnew middle\ntail");
    expect(lines).toEqual([
      { kind: "context", text: "keep" },
      { kind: "del", text: "old middle" },
      { kind: "add", text: "new middle" },
      { kind: "context", text: "tail" },
    ]);
  });

  test("interleaves changes via LCS instead of del-all/add-all", () => {
    const lines = computeLineDiff("a\nb\nc\nd", "a\nx\nc\nd\ne");
    expect(lines).toEqual([
      { kind: "context", text: "a" },
      { kind: "del", text: "b" },
      { kind: "add", text: "x" },
      { kind: "context", text: "c" },
      { kind: "context", text: "d" },
      { kind: "add", text: "e" },
    ]);
  });

  test("pure insertion yields only add lines", () => {
    expect(kinds(computeLineDiff("", "one\ntwo"))).toEqual(["add", "add"]);
  });

  test("pure removal yields only del lines", () => {
    expect(kinds(computeLineDiff("one\ntwo", ""))).toEqual(["del", "del"]);
  });

  test("collapses long unchanged runs into a counted hunk line", () => {
    const shared = Array.from({ length: 12 }, (_, index) => `line ${index}`).join("\n");
    const lines = computeLineDiff(`${shared}\nold tail`, `${shared}\nnew tail`);
    const hunk = lines.find((line) => line.kind === "hunk");
    expect(hunk?.collapsedCount).toBe(10);
    // 0 leading context (edge), hunk, 2 trailing context before the change.
    expect(kinds(lines)).toEqual(["hunk", "context", "context", "del", "add"]);
  });

  test("ignores a single trailing newline instead of diffing a phantom line", () => {
    expect(computeLineDiff("a\n", "a\nb\n")).toEqual([
      { kind: "context", text: "a" },
      { kind: "add", text: "b" },
    ]);
  });
});

describe("parseApplyPatch", () => {
  const patch = [
    "*** Begin Patch",
    "*** Update File: src/main.ts",
    "@@ function main()",
    " const x = 1;",
    "-console.log(x);",
    "+console.warn(x);",
    "*** Add File: src/new.ts",
    "+export const fresh = true;",
    "*** Delete File: src/old.ts",
    "*** End Patch",
  ].join("\n");

  test("splits a multi-file patch into per-file diffs", () => {
    const diffs = parseApplyPatch(patch);
    expect(diffs.map((diff) => diff.path)).toEqual(["src/main.ts", "src/new.ts", "src/old.ts"]);
    expect(diffs.map((diff) => diff.op)).toEqual(["edit", "create", "delete"]);
  });

  test("classifies +/-/space/@@ lines", () => {
    const [main] = parseApplyPatch(patch);
    expect(main.lines).toEqual([
      { kind: "hunk", text: "function main()" },
      { kind: "context", text: "const x = 1;" },
      { kind: "del", text: "console.log(x);" },
      { kind: "add", text: "console.warn(x);" },
    ]);
    expect(main.addedCount).toBe(1);
    expect(main.removedCount).toBe(1);
  });

  test("records renames from Move to directives", () => {
    const diffs = parseApplyPatch(
      "*** Begin Patch\n*** Update File: a.ts\n*** Move to: b.ts\n+x\n*** End Patch",
    );
    expect(diffs[0].path).toBe("a.ts → b.ts");
  });
});

describe("fileChangeDiffs", () => {
  test("Claude Edit input becomes a line diff with the file path", () => {
    const diffs = fileChangeDiffs({
      input: {
        file_path: "/repo/src/app.ts",
        old_string: "const a = 1;",
        new_string: "const a = 2;",
      },
    });
    expect(diffs).toHaveLength(1);
    expect(diffs[0].path).toBe("/repo/src/app.ts");
    expect(diffs[0].op).toBe("edit");
    expect(kinds(diffs[0].lines)).toEqual(["del", "add"]);
  });

  test("Claude Write input renders as an all-added create", () => {
    const diffs = fileChangeDiffs({
      input: { file_path: "/repo/new.ts", content: "line one\nline two\n" },
    });
    expect(diffs[0].op).toBe("create");
    expect(diffs[0].addedCount).toBe(2);
    expect(diffs[0].removedCount).toBe(0);
    expect(kinds(diffs[0].lines)).toEqual(["add", "add"]);
  });

  test("Claude MultiEdit concatenates per-edit diffs with hunk separators", () => {
    const diffs = fileChangeDiffs({
      input: {
        file_path: "/repo/multi.ts",
        edits: [
          { old_string: "first old", new_string: "first new" },
          { old_string: "second old", new_string: "second new" },
        ],
      },
    });
    expect(diffs).toHaveLength(1);
    expect(kinds(diffs[0].lines)).toEqual(["del", "add", "hunk", "del", "add"]);
    expect(diffs[0].addedCount).toBe(2);
    expect(diffs[0].removedCount).toBe(2);
  });

  test("NotebookEdit new_source renders as added lines", () => {
    const diffs = fileChangeDiffs({
      input: { notebook_path: "/repo/nb.ipynb", new_source: "import os" },
    });
    expect(diffs[0].path).toBe("/repo/nb.ipynb");
    expect(kinds(diffs[0].lines)).toEqual(["add"]);
  });

  test("Codex apply_patch text is parsed from a string input", () => {
    const diffs = fileChangeDiffs({
      input: "*** Begin Patch\n*** Update File: src/x.go\n-old\n+new\n*** End Patch",
    });
    expect(diffs[0].path).toBe("src/x.go");
    expect(kinds(diffs[0].lines)).toEqual(["del", "add"]);
  });

  test("Codex apply_patch text is found inside an input record", () => {
    const diffs = fileChangeDiffs({
      input: { input: "*** Begin Patch\n*** Add File: a.txt\n+hello\n*** End Patch" },
    });
    expect(diffs[0].op).toBe("create");
    expect(diffs[0].lines).toEqual([{ kind: "add", text: "hello" }]);
  });

  test("unrecognized input yields no diffs (generic fallback)", () => {
    expect(fileChangeDiffs({ input: { something: "else" } })).toEqual([]);
    expect(fileChangeDiffs({ input: undefined })).toEqual([]);
  });

  test("caps DiffLine allocation for huge writes but keeps counts accurate", () => {
    const content = Array.from({ length: 1500 }, (_, index) => `line ${index}`).join("\n");
    const [diff] = fileChangeDiffs({ input: { file_path: "/repo/huge.txt", content } });
    expect(diff.lines).toHaveLength(1000);
    expect(diff.truncatedLineCount).toBe(500);
    expect(diff.addedCount).toBe(1500);
  });
});

describe("commandExecutionView", () => {
  test("Claude Bash input: command string, raw output, implicit exit 0", () => {
    const view = commandExecutionView({
      status: "completed",
      input: { command: "bun test", description: "Run tests" },
      output: { text: "12 pass\n0 fail" },
    });
    expect(view.command).toBe("bun test");
    expect(view.output).toBe("12 pass\n0 fail");
    expect(view.exitCode).toBe(0);
    expect(view.durationText).toBeNull();
  });

  test("failed output with no explicit code shows no exit badge", () => {
    const view = commandExecutionView({
      status: "failed",
      input: { command: "false" },
      output: { text: "boom", is_error: true },
    });
    expect(view.exitCode).toBeNull();
  });

  test("extracts the exit code from error text", () => {
    const view = commandExecutionView({
      status: "failed",
      input: { command: "make" },
      output: { text: "make: *** [all] Error 2\nExit code: 2", is_error: true },
    });
    expect(view.exitCode).toBe(2);
  });

  test("Codex argv input unwraps bash -lc and parses the JSON envelope", () => {
    const view = commandExecutionView({
      status: "completed",
      input: { command: ["bash", "-lc", "ls -la"], timeout_ms: 10_000 },
      output: {
        text: JSON.stringify({
          output: "total 0\ndrwxr-xr-x  2 dev  wheel  64 .",
          metadata: { exit_code: 1, duration_seconds: 0.42 },
        }),
      },
    });
    expect(view.command).toBe("ls -la");
    expect(view.output).toBe("total 0\ndrwxr-xr-x  2 dev  wheel  64 .");
    expect(view.exitCode).toBe(1);
    expect(view.durationText).toBe("420ms");
  });

  test("plain argv joins with spaces", () => {
    const view = commandExecutionView({
      status: "completed",
      input: { command: ["git", "status", "--short"] },
    });
    expect(view.command).toBe("git status --short");
  });

  test("JSON-looking command output without the envelope is kept verbatim", () => {
    const text = '{"output": "not codex"}';
    const view = commandExecutionView({
      status: "completed",
      input: { command: "curl api" },
      output: { text },
    });
    expect(view.output).toBe(text);
  });

  test("in-progress item with partial output does not claim exit 0", () => {
    const view = commandExecutionView({
      status: "in_progress",
      input: { command: "bun run typecheck" },
      output: { text: "$ tsc --noEmit" },
    });
    expect(view.exitCode).toBeNull();
    expect(view.output).toBe("$ tsc --noEmit");
  });

  test("in-progress item (no output) has no exit code", () => {
    const view = commandExecutionView({ status: "in_progress", input: { command: "sleep 5" } });
    expect(view.exitCode).toBeNull();
    expect(view.output).toBeNull();
  });

  test("falls back to the item title when input is sparse", () => {
    const view = commandExecutionView({ status: "in_progress", input: undefined, title: "bun test" });
    expect(view.command).toBe("bun test");
  });
});

describe("formatDurationSeconds", () => {
  test("formats ms, seconds, and minutes", () => {
    expect(formatDurationSeconds(0.042)).toBe("42ms");
    expect(formatDurationSeconds(1.25)).toBe("1.3s");
    expect(formatDurationSeconds(59.4)).toBe("59.4s");
    expect(formatDurationSeconds(125)).toBe("2m 5s");
  });
});

describe("fileViewData", () => {
  test("Read tool with file_path yields path + preview", () => {
    const data = fileViewData({
      tool_name: "Read",
      input: { file_path: "/repo/src/main.ts" },
      output: { text: "1\tconst x = 1;" },
    });
    expect(data).toEqual({ path: "/repo/src/main.ts", preview: "1\tconst x = 1;" });
  });

  test("non-read tools are not treated as file views", () => {
    expect(
      fileViewData({ tool_name: "Grep", input: { path: "/repo" }, output: { text: "hit" } }),
    ).toBeNull();
  });

  test("read tool without a path falls back to generic rendering", () => {
    expect(fileViewData({ tool_name: "Read", input: {}, output: undefined })).toBeNull();
  });
});

describe("webSearchView", () => {
  test("extracts the query and embedded title/url result objects", () => {
    const view = webSearchView({
      input: { query: "tanstack router hash history" },
      output: {
        text:
          'Links: [{"title": "Hash History", "url": "https://tanstack.com/router/latest"}, ' +
          '{"title": "Routing Concepts", "url": "https://tanstack.com/router/concepts"}]',
      },
    });
    expect(view.query).toBe("tanstack router hash history");
    expect(view.results).toEqual([
      { title: "Hash History", url: "https://tanstack.com/router/latest" },
      { title: "Routing Concepts", url: "https://tanstack.com/router/concepts" },
    ]);
  });

  test("drops unsafe URLs and duplicates", () => {
    const view = webSearchView({
      input: { query: "x" },
      output: {
        text:
          '[{"title": "bad", "url": "javascript:alert(1)"}, ' +
          '{"title": "ok", "url": "https://example.com"}, ' +
          '{"title": "dup", "url": "https://example.com"}]',
      },
    });
    expect(view.results).toEqual([{ title: "ok", url: "https://example.com" }]);
  });

  test("WebFetch url doubles as the query; plain text passes through", () => {
    const view = webSearchView({
      input: { url: "https://docs.example.com/page", prompt: "summarize" },
      output: { text: "Plain summary, no links." },
    });
    expect(view.query).toBe("https://docs.example.com/page");
    expect(view.results).toEqual([]);
    expect(view.text).toBe("Plain summary, no links.");
  });
});

describe("clampTextLines", () => {
  test("returns untruncated short text", () => {
    expect(clampTextLines("a\nb", 5)).toEqual({
      text: "a\nb",
      truncated: false,
      totalLines: 2,
      hiddenLines: 0,
    });
  });

  test("clamps and counts hidden lines", () => {
    const clamp = clampTextLines("1\n2\n3\n4\n5", 2);
    expect(clamp.text).toBe("1\n2");
    expect(clamp.truncated).toBe(true);
    expect(clamp.hiddenLines).toBe(3);
  });
});
