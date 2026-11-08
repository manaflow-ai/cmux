// l10n-allow-file: gallery fixtures (sample prompts, replies and code), not shipped UI.
// The chat column (chatWidth.ts): one turn with prose, tool calls, a table and wide code at Settings >
// Agents > Chat Layout > Chat Text Width's default, at other widths and at Chat Full Width. Every
// pane draws the width set, capped only by the pane (https://github.com/manaflow-ai/cmux/issues/36299).
// Render it at 900, 1440 and 1920: the column is the same width in each that fits it.
import { agentPaneEntry, type AgentPaneVariant } from "../../../gallery/format";
import { activity, assistant, chat, summary, tool, user } from "../../../gallery/fixtures/acpmux";

const REPLY = [
  "The fetch helper now retries transient failures with exponential backoff and full jitter, so a burst of 429s from the API no longer fails the whole sync. Requests that are not safe to repeat still fail at once unless the caller passes a policy, and every retry is logged with its attempt number and delay so the support bundle shows what happened.",
  "",
  "- **GETs** retry `408`, `429` and gateway `5xx` errors, honoring `Retry-After` when the server sends one.",
  "- **POSTs** retry only with `retry: { attempts: 5 }` or inside `withRetry`.",
  "",
  "| Status | Retried | Note |",
  "| --- | --- | --- |",
  "| 408 | yes | request timeout |",
  "| 429 | yes | waits for `Retry-After`, capped at the policy's longest delay |",
  "| 500 | no | a server bug, not a blip |",
  "",
  "The new module:",
  "",
  "```ts",
  "export async function withRetry<T>(run: (attempt: number) => Promise<T>, policy: RetryPolicy = DEFAULT_RETRY_POLICY): Promise<T> {",
  "  for (let attempt = 1; ; attempt += 1) {",
  "    try {",
  "      return await run(attempt);",
  "    } catch (error) {",
  "      if (attempt >= policy.attempts || !isTransient(error)) throw error;",
  "      const delay = Math.min(policy.maxDelayMs, policy.baseDelayMs * 2 ** (attempt - 1)) * Math.random();",
  "      log.info(`retrying ${describeRequest(error)} after ${Math.round(delay)} ms (attempt ${attempt} of ${policy.attempts})`);",
  "      await sleep(delay);",
  "    }",
  "  }",
  "}",
  "```",
  "",
  "All 41 tests in `src/net` pass, including the new jitter bounds test.",
].join("\n");

const rows = chat([
  user("Add retries with backoff to the fetch helper, and make sure POSTs never retry on their own", 6),
  activity(
    [
      tool("Read src/net/client.ts", "read", "completed"),
      tool("Search for parseError", "search", "completed"),
      tool("Edit src/net/retry.ts", "edit", "completed"),
      tool("bun test src/net", "execute", "completed", { command: "bun test src/net", output: "41 pass\n0 fail" }),
    ],
    5.5,
  ),
  assistant(REPLY, 5),
  summary(5, { status: "completed", durationMs: 48_000, toolCount: 4 }),
]);

/// Content that cannot wrap: an unbroken token, a long URL, a wide table and a one-line command. The
/// column must hold it: the token and URL break, the table and code scroll inside their own boxes,
/// and nothing pushes the transcript wider than its pane.
const TOKEN = "sha256:" + "0123456789abcdef".repeat(16);
const OVERFLOW = [
  `The build failed on a cache key no line can break: ${TOKEN}`,
  "",
  `See https://github.com/manaflow-ai/cmux/actions/runs/42429560256/job/128575208330?pr=36342&check_suite_focus=true#step:7:1842 for the log.`,
  "",
  "| Job | Runner | Cache key | Started | Finished | Duration | Retries | Exit |",
  "| --- | --- | --- | --- | --- | --- | --- | --- |",
  `| react-apps-base-check | blacksmith-16vcpu-ubuntu-2404 | \`${TOKEN.slice(0, 90)}\` | 22:01:56 | 22:38:53 | 36m57s | 2 | 1 |`,
  "",
  "```sh",
  `CMUX_WEB_TEST_FILES="test/session-info-overlay-toggle.test.ts test/composer-inline-caret-gap.browser.test.ts test/accent-glass-invariants-6.test.ts" CMUX_WEB_TEST_JOBS=1 CMUX_WEB_TEST_RETRIES=0 bash ../scripts/ci/run-webviews-tests.sh --cache ${TOKEN}`,
  "```",
].join("\n");
const overflowRows = chat([user(`Why did the cache miss on ${TOKEN}?`, 6), assistant(OVERFLOW, 5)]);

/// The pane as the app pushes Settings' `agentPane.display.*` keys (`display`, chatDisplay.ts).
const variant = (display: Record<string, unknown>, note: string): AgentPaneVariant => ({
  note,
  snapshot: rows,
  display,
});

export default agentPaneEntry({
  id: "agent-pane.chat-width",
  title: "Chat column width",
  area: "Agent pane",
  height: 900,
  covers: ["agent-session/acpmux/VirtualTranscript.tsx#VirtualTranscript"],
  variants: {
    standard: variant({}, "Chat Text Width's default: an 800px column in any pane at least that wide."),
    narrow: variant({ "agentPane.display.width": 640 }, "Chat Text Width 640: a 640px column in every pane."),
    wide: variant({ "agentPane.display.width": 960 }, "Chat Text Width 960: a 960px column where the pane fits it."),
    "full-width": variant({ "agentPane.display.fullWidth": true }, "Chat Full Width: the column fills the pane."),
    overflow: {
      ...variant(
        {},
        "Content that cannot wrap stays inside the column: tokens break, tables and code scroll in place.",
      ),
      snapshot: overflowRows,
    },
    "overflow-full-width": {
      ...variant(
        { "agentPane.display.fullWidth": true },
        "The same content at Chat Full Width: it stays inside the pane.",
      ),
      snapshot: overflowRows,
    },
  },
});
