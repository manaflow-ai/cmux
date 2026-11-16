// l10n-allow-file: gallery fixtures (sample prompts and tool errors), not shipped UI.
// Failed tool calls (ToolRow.tsx, CommandRow.tsx, McpCallRows.tsx; Leo 2026-10-22: "we need to have
// prettier errors"): the row says what happened in a word and one line says why, in the tool's own
// words without its envelope; the raw result stays in the opened call. The fixtures are the shapes
// harnesses send: Claude Code's hook refusal, "Exit code N" over the output, its refusal when the
// person declined, a `<tool_use_error>`, a timeout; Codex's `{"status":"declined"}` and exit code;
// an MCP server's JSON error. Compare arms shows the `tool-error-look` experiment's three looks.
import { agentPaneEntry } from "../../../gallery/format";
import { activity, assistant, chat, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import { minutesAgo } from "../../../gallery/clock";
import type { AcpmuxActivity } from "../model";
import type { PlayContext } from "../../../gallery/play";
import { toolErrorLook } from "./toolError.experiment";
import { openEndedStretch } from "./endedStretchPlay";

const times = (at: number) => ({ startedAt: minutesAgo(at), endedAt: minutesAgo(at - 0.02) });

const shell = (command: string, description: string | undefined, output: string, at: number, exitCode?: number) =>
  tool(command, "execute", "failed", {
    command,
    ...(description ? { description } : {}),
    output,
    ...(exitCode === undefined ? {} : { exitCode }),
    ...times(at),
  });

/// Each call in its own run of a working chat, with the agent's note on it after: a note of two
/// paragraphs keeps the runs apart (turns.ts mergeShortNotes), so every call draws as its own row.
/// The stretch ended with its summary while the chat works on: under the live-turn-work
/// `line` a stretch still running draws none of its calls, only its notes and the live line
/// (turns.ts `codexRuns`). The ended stretch folds under its "Worked for" line, which draws its
/// notes and none of its calls (turnFoldReplies.experiment.ts `replies`): a variant draws its calls
/// only when its play opens that line (endedStretchPlay.ts), as `long-label` and `exit-opened` do.
const calls = (prompt: string, entries: [AcpmuxActivity, string][], harness = "claude") =>
  chat(
    [
      user(prompt, 6),
      ...entries.flatMap(([call, note], index) => [
        activity([call], 5.8 - index * 0.4),
        assistant(`${note}\n\nOn to the next step.`, 5.7 - index * 0.4),
      ]),
      summary(5.7 - entries.length * 0.4, { status: "completed", toolCount: entries.length }),
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

/// A finished turn whose run of four commands had one fail, as in the "Scheduled check" Leo said
/// yes to (2026-11-02): opened, the failed step is one plain line, "failed" at its edge, and its
/// error output waits behind the step's own chevron.
const ok = (command: string, description: string, at: number) =>
  tool(command, "execute", "completed", { command, description, output: "ok\n", exitCode: 0, ...times(at) });
const failedStep = chat(
  [
    user("Check the lanes and summarize what is stuck", 6),
    activity(
      [
        ok("acpmux ls --json > /tmp/ls.json", "Check states of my routed lanes", 5.8),
        shell(
          "sed -n '/^==== Stuck/,/^====/p' NOW.md | ==== ",
          "Read NOW.md and summarize stuck lanes",
          "Exit code 1\n(eval):1: ==== not found",
          5.6,
        ),
        ok("python3 - < summarize.py", "Summarize live lane states", 5.4),
        ok("python3 - < pending.py", "List live lanes with stuck or pending state", 5.2),
      ],
      5.8,
    ),
    assistant("One lane is paused on its queue: studio-mac/land-queue. Nothing else is stuck.", 5),
  ],
  { harness: "claude", model: "claude-opus-5-5" },
);

/// Failed calls whose labels are longer than the line: the label takes the ellipsis and the failure
/// word stays whole after it, as a command's "Failed" does (ToolRow.tsx; cmux#24339 put it inside
/// the cut words).
const longLabels = calls("Read the retry notes and the old reference", [
  [
    tool(
      "Read /Users/you/src/atlas-web/packages/network/src/retry/strategies/exponential-backoff/exponential-backoff-with-full-jitter-and-retry-budget.ts",
      "read",
      "failed",
      {
        output:
          "<tool_use_error>File does not exist. Current working directory: /Users/you/src/atlas-web</tool_use_error>",
        ...times(5.8),
      },
    ),
    "That file moved.",
  ],
  [
    tool(
      "Fetch https://docs.example.com/reference/networking/client-behaviour/retries/exponential-backoff-and-full-jitter-with-retry-budgets",
      "fetch",
      "failed",
      { output: "Request failed with status code 404 Not Found", ...times(5.4) },
    ),
    "The old reference is gone.",
  ],
  [
    tool(
      "Edit packages/network/src/retry/strategies/exponential-backoff/exponential-backoff-with-full-jitter-and-retry-budget.test.ts",
      "edit",
      "failed",
      { output: "The user doesn't want to proceed with this tool use.", ...times(5) },
    ),
    "You declined the test edit.",
  ],
]);

/// Two runs, a Read's and a command's, each with one failure, opened: the failed Read step and the
/// failed command step both say "Failed", capitalised alike (conversation.css; cmux#33759
/// capitalised only the command's).
const read = (title: string, at: number) =>
  tool(title, "read", "completed", { output: "# Retry notes\n", ...times(at) });
const mixedFailedStep = chat(
  [
    user("Check the retry notes and run the checks", 6),
    activity(
      [
        read("Read docs/retry.md", 5.9),
        tool("Read docs/retry-notes.md", "read", "failed", {
          output: "<tool_use_error>File does not exist.</tool_use_error>",
          ...times(5.8),
        }),
      ],
      5.9,
    ),
    assistant("One of the notes files is missing.\n\nRunning the checks next.", 5.7),
    activity(
      [
        shell("bun test src/net", "Run the network tests", "Exit code 1\n1 fail", 5.4),
        ok("git status --short", "Check the branch is clean", 5.2),
      ],
      5.4,
    ),
    assistant("The notes file is missing and one network test fails.", 5),
  ],
  { harness: "claude", model: "claude-opus-5-5" },
);

/// Opens every run's line, whatever it counts, to show their steps.
const openAnyRun = async (ctx: PlayContext) => {
  const closed = '.acpmux-row button.cv-tool.is-run[aria-expanded="false"]';
  await ctx.waitFor(() => ctx.document.querySelector("button.cv-tool.is-run[aria-expanded]"));
  while (ctx.document.querySelector(closed)) await ctx.click({ selector: closed });
  await ctx.waitFor(
    () => ctx.document.querySelectorAll(".cv-steps .cv-tool__failed, .cv-steps .cv-command__failed").length >= 2,
  );
};

/// Opens the run, to show its steps. A turn with no summary row draws as it came (turns.ts
/// `shapeTurn`), so this group already starts open: a click then closed it, and the wait raced its
/// close (it held only while the closing steps were still drawn; the reply under it rose as it shut).
/// The play clicks only a closed group.
const openRun = async (ctx: PlayContext) => {
  const run = ctx.find({ role: "button", name: /Ran 4 commands/ });
  if (run.getAttribute("aria-expanded") !== "true") await ctx.click({ role: "button", name: /Ran 4 commands/ });
  await ctx.waitFor(() => Boolean(ctx.document.querySelector(".cv-steps .cv-command__failed")));
};

/// Opens the traceback's call, to show its raw output under it. The call failed, so its row never
/// reads as what it would have done; it reads as the fixture's own description (commandActions.ts
/// commandSaid), which no label rule rewrites.
const openTraceback = async (ctx: PlayContext) => {
  await openEndedStretch(ctx);
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
    "agent-session/acpmux/conversation/ToolGroupRow.tsx",
  ],
  keywords: ["error", "failed", "hook", "denied", "exit code", "timeout", "mcp", "step", "group"],
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
    "failed-step": {
      note: 'A run of four commands with one failure, opened: for Codex parity the failure draws no word, count or tint (a screen reader still hears "1 failed" and "failed"), and the step\'s error output ("(eval):1: ==== not found") waits behind its own chevron.',
      snapshot: failedStep,
      play: openRun,
    },
    "long-label": {
      note: "Failed calls whose labels run past the line: each label takes the ellipsis to the line's end; the failure word (Failed, Denied) is for screen readers only (Codex parity).",
      snapshot: longLabels,
      play: openEndedStretch,
    },
    "failed-step-mixed": {
      note: 'A run where a Read and a command failed, opened: both steps say "Failed" to a screen reader and draw no word (Codex parity).',
      snapshot: mixedFailedStep,
      play: openAnyRun,
    },
    "exit-opened": {
      note: "The traceback's call opened: the Shell block says Exit code 1 once, under the output.",
      snapshot: claudeCode,
      play: openTraceback,
    },
  },
  experiment: { definition: toolErrorLook, script: [{ name: "open the traceback", run: openTraceback }] },
});
