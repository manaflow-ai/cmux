// l10n-allow-file: gallery fixtures (sample prompts and tool errors), not shipped UI.
// Failed tool calls (ToolRow.tsx, CommandRow.tsx, McpCallRows.tsx; Leo 2026-10-22: "we need to have
// prettier errors"): the row says what happened in a word and one line says why, in the tool's own
// words without its envelope; the raw result stays in the opened call. The fixtures are the shapes
// harnesses send: Claude Code's hook refusal, "Exit code N" over the output, its refusal when the
// person declined, a `<tool_use_error>`, a timeout; Codex's `{"status":"declined"}` and exit code;
// an MCP server's JSON error. Compare arms shows the `tool-error-look` experiment's three looks.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, tool, user } from "../../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../../gallery/clock";
import type { AcpmuxActivity } from "../model";
import type { PlayContext } from "../../../gallery/play";
import { toolErrorLook } from "./toolError.experiment";

const times = (at: number) => ({ startedAt: minutesAgo(at), endedAt: minutesAgo(at - 0.02) });

const shell = (command: string, description: string | undefined, output: string, at: number, exitCode?: number) =>
  tool(command, "execute", "failed", {
    command,
    ...(description ? { description } : {}),
    output,
    ...(exitCode === undefined ? {} : { exitCode }),
    ...times(at),
  });

/// Each call in its own run of a working turn, with the agent's note on it after: a note of two
/// paragraphs keeps the runs apart (turns.ts mergeShortNotes), so every call draws as its own row.
const calls = (prompt: string, entries: [AcpmuxActivity, string][], harness = "claude") =>
  chat(
    [
      user(prompt, 6),
      ...entries.flatMap(([call, note], index) => [
        activity([call], 5.8 - index * 0.4),
        assistant(`${note}\n\nOn to the next step.`, 5.7 - index * 0.4),
      ]),
    ],
    { isWorking: true, harness, model: harness === "codex" ? "gpt-5.5-codex" : "claude-opus-5-5" },
  );

const claudeCode = calls("Land the retry fix and check the tests", [
  [
    shell(
      "gh pr merge 412 --squash",
      "Merge the retry PR",
      "PreToolUse:Bash hook error: Blocked: `gh pr merge` needs a passing review receipt on the head; post one first, then merge.",
      5.8,
    ),
    "The merge hook wants a review first.",
  ],
  [
    shell(
      "git push --force origin main",
      "Push the fix",
      "The user doesn't want to proceed with this tool use. The tool use was rejected (eg. if it was a file edit, the new_string was NOT written to the file). STOP what you are doing and wait for the user to tell you how to proceed.",
      5,
    ),
    "Waiting for your call on the push.",
  ],
  [
    shell(
      "python3 scripts/check_retry.py",
      "Check the retry schedule",
      [
        "Exit code 1",
        "Traceback (most recent call last):",
        '  File "scripts/check_retry.py", line 14, in <module>',
        "    delays = schedule(attempts=5)",
        '  File "scripts/check_retry.py", line 9, in schedule',
        "    return [base * 2**n for n in range(attempts)]",
        "TypeError: unsupported operand type(s) for *: 'NoneType' and 'int'",
      ].join("\n"),
      5.4,
    ),
    "The schedule has no base delay yet.",
  ],
  [
    tool("Read src/net/retry.ts", "read", "failed", {
      output:
        "<tool_use_error>File does not exist. Current working directory: /Users/you/src/atlas-web</tool_use_error>",
      ...times(4.6),
    }),
    "The retry module is not written yet.",
  ],
  [
    shell("bun test src/net --watch", "Run the network tests", "Exit code 143\nCommand timed out after 2m 0s", 4.2),
    "The watch run never ends; running it once instead.",
  ],
]);

const codex = calls(
  "Clean the build folder and rebuild",
  [
    [
      tool("rm -rf build", "execute", "failed", {
        command: "rm -rf build",
        output: '{"duration_ms": null, "exit_code": null, "status": "declined"}',
        ...times(5.8),
      }),
      "You declined the delete, so the build folder stays.",
    ],
    [
      shell(
        "cargo build --release",
        undefined,
        [
          "   Compiling retry v0.3.1 (/Users/you/src/retry)",
          "error[E0425]: cannot find value `base_delay` in this scope",
          "  --> src/schedule.rs:9:12",
          "   |",
          "9  |     delay: base_delay * 2u32.pow(n),",
          "   |            ^^^^^^^^^^ not found in this scope",
          "",
          "error: could not compile `retry` (lib) due to 1 previous error",
        ].join("\n"),
        5.4,
        101,
      ),
      "The schedule still names the old field.",
    ],
  ],
  "codex",
);

const mcp = calls("Take a screenshot of the preview and read the inbox", [
  [
    tool("mcp__cmux__browser_screenshot", "other", "failed", {
      inputSummary: JSON.stringify({ tab: "preview" }),
      output: JSON.stringify({
        error: {
          code: "browser_host.unavailable",
          details: {},
          message: "no browser host is listening; open a browser tab in cmux first",
        },
      }),
      ...times(5.8),
    }),
    "No browser tab is open yet.",
  ],
  [
    tool("mcp__mail__read_inbox", "other", "failed", {
      inputSummary: JSON.stringify({ limit: 20 }),
      output: JSON.stringify({
        content: [{ type: "text", text: "Mail server refused the login: app password expired" }],
        isError: true,
      }),
      ...times(5.4),
    }),
    "The mail account needs a new app password.",
  ],
  [
    tool("Fetch https://example.com/api/v2/retries", "fetch", "failed", {
      output: "Request failed with status code 404 Not Found",
      ...times(5),
    }),
    "The v2 reference is gone; the docs cover it.",
  ],
]);

/// Opens the traceback's call, to show its raw output under it.
const openTraceback = async (ctx: PlayContext) => {
  await ctx.click({ role: "button", name: /Check the retry schedule/ });
  await ctx.waitFor(() => Boolean(ctx.document.querySelector(".cv-shell__command")));
};

export default agentPaneEntry({
  id: "agent-pane.tool-errors",
  title: "Tool errors",
  area: "Agent pane",
  height: 900,
  covers: [
    "agent-session/acpmux/conversation/ToolFailureCause.tsx",
    "agent-session/acpmux/conversation/ToolRow.tsx",
    "agent-session/acpmux/conversation/CommandRow.tsx",
    "agent-session/acpmux/conversation/McpCallRows.tsx",
  ],
  keywords: ["error", "failed", "hook", "denied", "exit code", "timeout", "mcp"],
  variants: {
    "claude-code": {
      note: "Claude Code: a hook refusal, Exit code 1 with a traceback, a declined edit, a tool_use_error, a timeout.",
      snapshot: claudeCode,
    },
    codex: {
      note: 'Codex: a declined command (its `{"status":"declined"}`), and a build that exited 101.',
      snapshot: codex,
    },
    mcp: {
      note: "An MCP server's JSON error, an MCP result marked isError, a fetch that got a 404.",
      snapshot: mcp,
    },
    "exit-opened": {
      note: "The traceback's call opened: the Shell block says Exit code 1 once, under the output.",
      snapshot: claudeCode,
      play: openTraceback,
    },
  },
  experiment: { definition: toolErrorLook, script: [{ name: "open the traceback", run: openTraceback }] },
});
