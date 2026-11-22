import { describe, expect, test } from "bun:test";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";
import { mergeToolItem, shellCommand } from "../direct";
import { ShellBlock } from "./ShellBlock";

describe("shell calls", () => {
  test("the command comes from rawInput, as a string or an argv array", () => {
    expect(shellCommand({ command: "bun test Sources/Fleet", cwd: "~/code/cmux" })).toBe("bun test Sources/Fleet");
    expect(shellCommand({ command: ["git", "status", "--short"] })).toBe("git status --short");
    // A script run through a shell shows as the script; other parts keep their quoting.
    expect(shellCommand({ command: ["/bin/zsh", "-lc", "cd x && bun test"] })).toBe("cd x && bun test");
    expect(shellCommand({ command: ["bash", "-c", "ls"] })).toBe("ls");
    expect(shellCommand({ command: ["rg", "-n", "keep 3|newest", "tools"] })).toBe("rg -n 'keep 3|newest' tools");
    expect(shellCommand({ command: ["echo", "it's"] })).toBe("echo 'it'\\''s'");
    expect(shellCommand({ command: [] })).toBeUndefined();
    expect(shellCommand({ arguments: { code: "await cua.getState()" } })).toBeUndefined();
    expect(shellCommand(undefined)).toBeUndefined();
  });

  /// Codex's shape: the call starts with its command, and the update carries rawOutput only.
  test("a Codex call keeps its command and takes the exit code and output from rawOutput", () => {
    const started = mergeToolItem(
      undefined,
      {
        toolCallId: "c",
        kind: "execute",
        title: "cat SKILL.md",
        status: "in_progress",
        rawInput: { command: "cat SKILL.md" },
      },
      "c",
      "",
    );
    expect(started.tool?.command).toBe("cat SKILL.md");
    const done = mergeToolItem(
      started,
      {
        toolCallId: "c",
        status: "failed",
        rawOutput: { exit_code: 1, formatted_output: "cat: SKILL.md: No such file\n" },
      },
      "c",
      "",
    );
    expect(done.tool).toMatchObject({ command: "cat SKILL.md", exitCode: 1, output: "cat: SKILL.md: No such file\n" });
  });

  test("content output wins over rawOutput", () => {
    const item = mergeToolItem(
      undefined,
      { toolCallId: "c", kind: "execute", rawOutput: { exit_code: 0, formatted_output: "raw" } },
      "c",
      "from content",
    );
    expect(item.tool).toMatchObject({ output: "from content", exitCode: 0 });
  });
});

describe("Shell block", () => {
  const html = (props: Parameters<typeof ShellBlock>[0]) => renderToStaticMarkup(createElement(ShellBlock, props));

  test("shows the command line and its output", () => {
    const markup = html({ command: "bun test", output: "2 pass", exitCode: 0 });
    expect(markup).toContain(">Shell<");
    expect(markup).toContain("$ bun test");
    expect(markup).toContain("2 pass");
    expect(markup).not.toContain("Exit code");
  });

  test("a failed command shows its exit code", () => {
    expect(html({ command: "codex-cua apps", output: "error -10000", exitCode: 1 })).toContain("Exit code 1");
  });

  test("a running command shows the command before any output", () => {
    const markup = html({ command: "bun install" });
    expect(markup).toContain("$ bun install");
    expect(markup).not.toContain("cv-shell__output");
  });
});
