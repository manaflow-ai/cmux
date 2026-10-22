// l10n-allow-file: test fixtures (tool results in the harnesses' words), not shipped UI.
// A failed tool call says what happened in a word and why in one line (Leo 2026-10-22: "we need to
// have prettier errors"): toolFailure.ts reads the harness's raw result, the rows draw it.
import { afterEach, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxActivity } from "../src/agent-session/acpmux/model";
import { CommandRow } from "../src/agent-session/acpmux/conversation/CommandRow";
import { ToolRow } from "../src/agent-session/acpmux/conversation/ToolRow";
import { toolFailure } from "../src/agent-session/acpmux/conversation/toolFailure";

type Tool = NonNullable<AcpmuxActivity["tool"]>;
const call = (output: string, extra: Partial<Tool> = {}): Tool => ({
  id: "t",
  title: "Bash",
  kind: "execute",
  status: "failed",
  command: "make",
  output,
  ...extra,
});
const item = (tool: Tool): AcpmuxActivity => ({ kind: "tool", text: tool.title, tool });
const words = (html: string) =>
  html
    .replace(/<[^>]+>/g, " ")
    .replace(/&#x27;/g, "'")
    .replace(/&quot;/g, '"')
    .replace(/\s+/g, " ")
    .trim();

afterEach(() => {
  globalThis.cmuxExperiments = undefined;
});

test("a call that did not fail has no failure", () => {
  expect(toolFailure(call("ok", { status: "completed" }))).toBeUndefined();
  expect(toolFailure(call("", { status: "completed", exitCode: 0 }))).toBeUndefined();
});

test("a hook's refusal names the hook and its reason, without the harness's lead", () => {
  const failure = toolFailure(call("PreToolUse:Bash hook error: Blocked: `gh pr merge` needs a review receipt."));
  expect(failure).toMatchObject({ kind: "hook", hook: "PreToolUse", cause: "`gh pr merge` needs a review receipt." });
});

test("Claude Code's Exit code line becomes the exit code, and the cause is the error line", () => {
  const output = [
    "Exit code 1",
    "Traceback (most recent call last):",
    '  File "x.py", line 2, in <module>',
    "TypeError: unsupported operand",
  ].join("\n");
  const failure = toolFailure(call(output));
  expect(failure).toMatchObject({ kind: "exit", exitCode: 1, cause: "TypeError: unsupported operand" });
  // The Shell block draws the output without the line, and says the code itself.
  expect(failure?.output?.startsWith("Traceback")).toBe(true);
});

test("a command's last line names the cause when no line says error", () => {
  expect(toolFailure(call("Exit code 1\n(eval):1: no matches found: --include=*.md"))?.cause).toBe(
    "(eval):1: no matches found: --include=*.md",
  );
  expect(toolFailure(call("Exit code 137"))).toMatchObject({ kind: "exit", exitCode: 137, cause: undefined });
});

test("Codex's own exit code wins, with the error line of its output", () => {
  const failure = toolFailure(
    call("error[E0425]: cannot find value\n  --> src/a.rs:9:12\nerror: could not compile `retry`", { exitCode: 101 }),
  );
  expect(failure).toMatchObject({ kind: "exit", exitCode: 101, cause: "could not compile `retry`" });
});

test("a declined call is denied, with what the person said when they said something", () => {
  expect(
    toolFailure(
      call("The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit…"),
    ),
  ).toMatchObject({ kind: "denied", cause: undefined });
  expect(
    toolFailure(call("The user doesn't want to proceed with this tool use. the user said:\nuse the staging db instead")),
  ).toMatchObject({ kind: "denied", cause: "use the staging db instead" });
  expect(toolFailure(call('{"duration_ms": null, "exit_code": null, "status": "declined"}'))?.kind).toBe("denied");
  // A shell's own "Permission denied" is not the person declining.
  expect(toolFailure(call("Exit code 1\nbash: ./run.sh: Permission denied"))?.kind).toBe("exit");
});

test("a timeout says so in its word alone", () => {
  expect(toolFailure(call("Exit code 143\nCommand timed out after 2m 0s"))).toMatchObject({
    kind: "timeout",
    exitCode: 143,
    cause: undefined,
  });
});

test("envelopes give their message: tool_use_error tags, JSON errors, MCP isError results", () => {
  expect(
    toolFailure(call("<tool_use_error>File has not been read yet. Read it first.</tool_use_error>", { kind: "edit" }))
      ?.cause,
  ).toBe("File has not been read yet. Read it first.");
  expect(
    toolFailure(call('{"error":{"code":"browser_host.unavailable","details":{},"message":"no browser host"}}'))?.cause,
  ).toBe("no browser host (browser_host.unavailable)");
  expect(toolFailure(call('{"error":"rate limited"}'))?.cause).toBe("rate limited");
  expect(
    toolFailure(call(JSON.stringify({ content: [{ type: "text", text: "login refused" }], isError: true })))?.cause,
  ).toBe("login refused");
  expect(toolFailure(call("Error: ENOENT: no such file, open 'a.txt'"))?.cause).toBe(
    "ENOENT: no such file, open 'a.txt'",
  );
});

test("a long result is read only at its ends, and a long cause is cut", () => {
  const failure = toolFailure(call(`Exit code 2\n${"noise\n".repeat(200_000)}fatal: ${"x".repeat(1_000)}`));
  expect(failure?.exitCode).toBe(2);
  expect(failure?.cause?.length).toBeLessThanOrEqual(300);
  expect(failure?.cause?.startsWith("x")).toBe(true);
});

test("a command row says the word in the error tone and the cause on a quiet line under it", () => {
  const html = renderToStaticMarkup(
    <CommandRow item={item(call("PreToolUse:Bash hook error: Blocked: needs a review.", { description: "Merge" }))} />,
  );
  expect(html).toMatch(/class="cv-command__failed">blocked</);
  expect(html).toContain('class="cv-tool-error"');
  expect(words(html)).toContain("PreToolUse needs a review.");
  // Claude Code's exit line reads as the row's "Exit 1".
  const exited = renderToStaticMarkup(<CommandRow item={item(call("Exit code 1\nmake: *** [all] Error 2"))} />);
  expect(exited).toMatch(/class="cv-command__failed">Exit 1</);
  expect(words(exited)).toContain("make: *** [all] Error 2");
});

test("a lone call says denied in red, and a declined call with no words adds no line", () => {
  const html = renderToStaticMarkup(
    <ToolRow
      item={item(
        call("The user doesn't want to proceed with this tool use.", { title: "Edit a.ts", kind: "edit", command: undefined }),
      )}
    />,
  );
  expect(html).toMatch(/class="cv-tool__failed"> denied</);
  expect(html).not.toContain("cv-tool-error");
});

test("the arms put the cause on the row, or in a card with Copy error", () => {
  const tool = call("<tool_use_error>File has not been read yet.</tool_use_error>", {
    title: "Write a.ts",
    kind: "edit",
    command: undefined,
  });
  globalThis.cmuxExperiments = { "tool-error-look": "inline" };
  const inline = renderToStaticMarkup(<ToolRow item={item(tool)} />);
  expect(inline).toContain("cv-tool-error__inline");
  expect(inline).not.toContain('class="cv-tool-error"');
  globalThis.cmuxExperiments = { "tool-error-look": "card" };
  const card = renderToStaticMarkup(<ToolRow item={item(tool)} />);
  expect(card).toContain("cv-tool-error-card");
  expect(words(card)).toContain("File has not been read yet. Copy error");
});
