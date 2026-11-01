// l10n-allow-file: test fixtures (tool results in the harnesses' words), not shipped UI.
// A failed tool call says what happened in a word and why in one line (Leo 2026-10-22: "we need to
// have prettier errors"): toolFailure.ts reads the harness's raw result, the rows draw it.
import { afterEach, expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { AcpmuxActivity } from "../src/agent-session/acpmux/model";
import { CommandRow } from "../src/agent-session/acpmux/conversation/CommandRow";
import { ToolRow } from "../src/agent-session/acpmux/conversation/ToolRow";
import { ToolRun } from "../src/agent-session/acpmux/conversation/ToolRun";
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
  // Opened, the call shows the hook's words without the harness's envelope.
  expect(failure?.output).toBe("`gh pr merge` needs a review receipt.");
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
      call(
        "The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit…",
      ),
    ),
  ).toMatchObject({ kind: "denied", cause: undefined });
  expect(
    toolFailure(
      call("The user doesn't want to proceed with this tool use. the user said:\nuse the staging db instead"),
    ),
  ).toMatchObject({ kind: "denied", cause: "use the staging db instead" });
  expect(toolFailure(call('{"duration_ms": null, "exit_code": null, "status": "declined"}'))?.kind).toBe("denied");
  // A shell's own "Permission denied" is not the person declining.
  expect(toolFailure(call("Exit code 1\nbash: ./run.sh: Permission denied"))?.kind).toBe("exit");
});

test("a timeout says so in its word alone", () => {
  const failure = toolFailure(call("Exit code 143\nCommand timed out after 2m 0s"));
  expect(failure).toMatchObject({ kind: "timeout", exitCode: 143 });
  expect(failure?.cause).toBeUndefined();
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
  // A hook's block reads "blocked by hook" alone, as Claude Code desktop draws it: no "PreToolUse"
  // and no line of its words until it is opened (Leo, 2026-10-31: "WHY IS THERE PRETOOLUSE").
  const html = renderToStaticMarkup(
    <CommandRow item={item(call("PreToolUse:Bash hook error: Blocked: needs a review.", { description: "Merge" }))} />,
  );
  expect(html).toMatch(/class="cv-command__failed"[^>]*>blocked by hook</);
  expect(html).not.toContain('class="cv-tool-error"');
  expect(words(html)).not.toContain("PreToolUse");
  expect(words(html)).not.toContain("needs a review.");
  // Claude Code's exit line reads as the row's "Exit 1".
  const exited = renderToStaticMarkup(<CommandRow item={item(call("Exit code 1\nmake: *** [all] Error 2"))} />);
  expect(exited).toMatch(/class="cv-command__failed"[^>]*>Exit 1</);
  expect(words(exited)).toContain("make: *** [all] Error 2");
});

test("a lone call says denied in red, and a declined call with no words adds no line", () => {
  const html = renderToStaticMarkup(
    <ToolRow
      item={item(
        call("The user doesn't want to proceed with this tool use.", {
          title: "Edit a.ts",
          kind: "edit",
          command: undefined,
        }),
      )}
    />,
  );
  expect(html).toMatch(/class="cv-tool__failed"[^>]*> denied</);
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
  expect(words(card)).toContain("File has not been read yet.");
  expect(card).toContain('aria-label="Copy error"');
});

test("output that only mentions a denial or a timeout still reads as its exit", () => {
  expect(toolFailure(call("Exit code 1\nOAuth: user denied access\nerror: login failed"))?.kind).toBe("exit");
  expect(
    toolFailure(call("Exit code 2\nstep 1\nCommand timed out after 5s (retrying)\nstep 2 ok\nFAIL 1 test")),
  ).toMatchObject({ kind: "exit", exitCode: 2 });
});

test("a capitalised word is not an errno code, and a failed call that exited 0 blames no plain line", () => {
  expect(toolFailure(call("Exit code 1\nerror: 2 tests failed\nExpected: 3\nElapsed 1.2s"))?.cause).toBe(
    "2 tests failed",
  );
  expect(toolFailure(call("ENOENT: no such file\nDone.", { exitCode: 1 }))?.cause).toBe("ENOENT: no such file");
  expect(toolFailure(call("Done.", { exitCode: 0 }))).toMatchObject({ kind: "error", cause: undefined });
});

test("a large JSON error is read whole", () => {
  const big = JSON.stringify({ error: { message: "quota exceeded", data: "x".repeat(20_000) } });
  expect(toolFailure(call(big))?.cause).toBe("quota exceeded");
});

test("a folded run says how many of its calls failed", () => {
  const html = renderToStaticMarkup(
    <ToolRun items={[item(call("Exit code 1\nboom")), item(call("ok", { status: "completed" }))]} disclosureKey="r">
      {null}
    </ToolRun>,
  );
  expect(words(html)).toContain("1 failed");
});

test("a failed test run that quotes a denial is its exit, not a denial", () => {
  const output = [
    "Exit code 1",
    "FAIL permissions.test.ts",
    'Expected: "user declined"',
    "AssertionError: expected 403, received 500",
  ].join("\n");
  expect(toolFailure(call(output))).toMatchObject({
    kind: "exit",
    exitCode: 1,
    cause: "AssertionError: expected 403, received 500",
  });
  expect(toolFailure(call("user denied access to the keychain", { exitCode: 1 }))?.kind).toBe("exit");
});

test("the cause leaves out the context a host injects, as the opened call does", () => {
  const injected = "<system-reminder>ambient UI state</system-reminder>\nError: server unavailable";
  expect(toolFailure(call(injected, { kind: "fetch", command: undefined }))?.cause).toBe("server unavailable");
  const mcp = JSON.stringify({ content: [{ type: "text", text: injected }], isError: true });
  expect(toolFailure(call(mcp, { title: "mcp__mail__read", kind: "other", command: undefined }))?.cause).toBe(
    "server unavailable",
  );
});

test("a cause in any script keeps its words", () => {
  expect(toolFailure(call('{"error":"访问被拒绝"}', { command: undefined, kind: "other" }))?.cause).toBe("访问被拒绝");
  expect(toolFailure(call("PreToolUse:Bash hook error: Blocked: 请先运行测试"))).toMatchObject({
    kind: "hook",
    cause: "请先运行测试",
  });
  expect(toolFailure(call("Exit code 1\nОшибка: файл не найден"))?.cause).toBe("Ошибка: файл не найден");
});

test("a fenced result loses its exit line too, so the Shell block says it once", () => {
  const failure = toolFailure(call("```\nExit code 1\nbuild failed\n```"));
  expect(failure).toMatchObject({ kind: "exit", exitCode: 1, output: "build failed" });
});

test("claude-agent-acp's refusal is a denial, and a zero-count summary is never the cause", () => {
  expect(toolFailure(call("User refused permission to run tool"))?.kind).toBe("denied");
  expect(toolFailure(call("Exit code 1\nerror: x.ts:3 missing return\nFound 0 errors in 2 other files"))?.cause).toBe(
    "x.ts:3 missing return",
  );
});

test("Copy error copies the result as drawn: no colour codes, fence or injected context", () => {
  const failure = toolFailure(
    call("<system-reminder>ambient</system-reminder>\n\u001b[31mError: boom\u001b[0m", {
      kind: "other",
      command: undefined,
    }),
  );
  expect(failure?.detail).toBe("Error: boom");
});

test("a command that ran and printed a refusal or a hook's words reads as its exit", () => {
  expect(toolFailure(call('{"status":"declined","error":"payment declined"}', { exitCode: 22 }))).toMatchObject({
    kind: "exit",
    exitCode: 22,
    cause: "payment declined",
  });
  expect(toolFailure(call("Exit code 1\nPreToolUse:Bash hook error: Blocked: fixture"))?.kind).toBe("exit");
});

test("context injected inside an MCP text block's own JSON stays out of the cause", () => {
  const inner = JSON.stringify({
    error: "<system-reminder>ambient UI state</system-reminder>\nError: server unavailable",
  });
  const mcp = JSON.stringify({ content: [{ type: "text", text: inner }], isError: true });
  expect(toolFailure(call(mcp, { title: "mcp__mail__read", kind: "other", command: undefined }))?.cause).toBe(
    "server unavailable",
  );
});

test("a hook's command in brackets stays out of its reason", () => {
  const failure = toolFailure(call("PreToolUse:Bash hook error: [~/.claude/hooks/guard.sh]: Blocked: needs a review."));
  expect(failure).toMatchObject({ kind: "hook", hook: "PreToolUse", cause: "needs a review." });
});

test("Copy error keeps Claude Code's Exit code line", () => {
  const failure = toolFailure(call("Exit code 2\nmake: *** [all] Error 2"));
  expect(failure?.detail).toBe("Exit code 2\nmake: *** [all] Error 2");
  expect(failure?.output).toBe("make: *** [all] Error 2");
});

test("a call with its own exit code keeps an output line that names another", () => {
  const failure = toolFailure(call("Exit code 3\nreal error here", { exitCode: 1 }));
  expect(failure).toMatchObject({ kind: "exit", exitCode: 1, output: undefined });
  expect(toolFailure(call("Exit code 1\nboom", { exitCode: 1 }))?.output).toBe("boom");
});

test("a progress bar's carriage returns stay in the output, as for a call that worked", () => {
  const failure = toolFailure(call("Exit code 1\n10%\r50%\r\nerror: disk full\r\n"));
  expect(failure?.output).toBe("10%\r50%\nerror: disk full\n");
  expect(failure?.cause).toBe("disk full");
});

test("a long result's tail is read from a whole line", () => {
  const cut = `${"a".repeat(4_500)} denied ${"y".repeat(100)}`;
  const failure = toolFailure(call(`Exit code 1\n${cut}\n${"z".repeat(3_800)}`));
  // The line the tail window cuts ("…aaa denied yyy") is not the cause; the last line is.
  expect(failure?.cause).toBe(`${"z".repeat(299)}…`);
});

test("context injected before an MCP text block's JSON stays out of the cause", () => {
  const text = `<system-reminder>ambient</system-reminder>\n${JSON.stringify({ error: { message: "quota spent" } })}`;
  const failure = toolFailure(
    call(JSON.stringify({ content: [{ type: "text", text }], isError: true }), { kind: "other", command: undefined }),
  );
  expect(failure?.cause).toBe("quota spent");
});

test("a failed call that went on in the background shows no cause under its row", () => {
  const tool = call("Exit code 1\nerror: port in use", { background: { state: "failed", endedAt: 0 } });
  const html = renderToStaticMarkup(<CommandRow item={item(tool)} />);
  expect(html).not.toContain("cv-tool-error");
});

test("a line a progress bar redrew reads as the terminal drew it", () => {
  expect(toolFailure(call("Exit code 1\n10%\r50% error: disk full"))?.cause).toBe("50% error: disk full");
});

test("a long result whose last line outgrows the tail window still reads that line", () => {
  const failure = toolFailure(call(`Exit code 1\n${"x".repeat(5_000)}\nfatal: ${"q".repeat(5_000)}`));
  expect(failure?.cause).toBe(`${"q".repeat(299)}…`);
});

test("a lone shell that ended in the background keeps its background mark, not a failure", () => {
  const tool = call("error: port in use", {
    status: "completed",
    exitCode: 1,
    background: { state: "failed", endedAt: 0 },
  });
  const html = renderToStaticMarkup(<ToolRow item={item(tool)} />);
  expect(html).toContain('data-state="failed"');
  expect(html).not.toContain("cv-tool__failed");
  expect(html).not.toContain("cv-tool-error");
});
