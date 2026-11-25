// l10n-allow-file: debug fixture prompts, commands and outputs, not shipped UI.
// A run of shell calls summarized as Claude Code desktop summarizes one, for `debug.agent_pane
// seed_rows` with `fixture: "tool-summary"`, so a capture shows it in the real app (Leo, 2026-11-03:
// "hmm claude code desktop's summarization of tool calls/parsing of them seem kinda good?"): two
// background commands that completed, one that failed there and one still running, a call that
// failed, and two that went through, each with Claude's Bash description. The same calls as the
// gallery's `agent-pane.claude-desktop-tool-summary`; every name and path in it is made up.
import type { AcpmuxActivity, AcpmuxRow } from "./model";

const SECOND = 1_000;

type Shell = NonNullable<AcpmuxActivity["tool"]>;

export function toolSummaryRows(at: number): AcpmuxRow[] {
  /// A shell call with Claude's Bash description, its command and what it printed.
  const shell = (n: number, description: string, command: string, fields: Partial<Shell>): AcpmuxActivity => ({
    kind: "tool",
    text: command,
    tool: {
      id: `tool-summary-${n}`,
      title: command,
      kind: "execute",
      status: "completed",
      description,
      command,
      startedAt: at + (4 + n * 3) * SECOND,
      endedAt: at + (5 + n * 3) * SECOND,
      ...fields,
    },
  });
  const items = [
    shell(1, "Find retryDelay references in the network layer", "rg -n 'retryDelay' src/net", {
      background: { state: "completed", endedAt: at + 9 * SECOND },
      output: "src/net/retry.ts:14:export const retryDelay = (n: number) => 250 * 2 ** n;\n",
    }),
    shell(
      2,
      "Count the retry fixture cases",
      "f=fixtures/retry-cases.json; ls $f 2>&1; [ -f $f ] && jq '.cases | length' $f",
      {
        status: "failed",
        exitCode: 1,
        output: "ls: fixtures/retry-cases.json: No such file or directory\n",
      },
    ),
    shell(3, "Run the retry tests", "bun test src/net/retry.test.ts", {
      exitCode: 0,
      output: "12 pass\n0 fail\n",
    }),
    // A background shell that failed there: its launch completed, its background state failed.
    shell(4, "Check the local API is up", "curl -sf http://localhost:4000/health", {
      background: { state: "failed", endedAt: at + 18 * SECOND },
      output: "curl: (7) Failed to connect to localhost port 4000\n",
    }),
    shell(5, "Build the docs site", "bun run docs:build", {
      background: { state: "completed", endedAt: at + 24 * SECOND },
      output: "built 42 pages in 3.1s\n",
    }),
    shell(6, "Start the dev server", "bun run dev", {
      background: { state: "running" },
      output: "listening on http://localhost:5173\n",
    }),
    shell(7, "List recent network-layer commits", "git log --oneline -5 -- src/net", {
      exitCode: 0,
      output: "a1b2c3d net: retry on 503\n9f8e7d6 net: typed errors\n",
    }),
  ];
  return [
    { id: "tool-summary-user", version: 1, at, kind: "user", text: "Why are the retry tests slow?" },
    { id: "tool-summary-activity", version: 1, at: at + 4 * SECOND, kind: "activity", toolCount: items.length, items },
    {
      id: "tool-summary-reply",
      version: 1,
      at: at + 30 * SECOND,
      kind: "assistant",
      text: "The retry tests pass, but the fixture file is missing and the local API isn't up, so two checks failed. The dev server is still running in the background.",
    },
  ] as AcpmuxRow[];
}
