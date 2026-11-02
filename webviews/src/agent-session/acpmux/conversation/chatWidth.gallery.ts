// l10n-allow-file: gallery fixtures (sample prompts, replies and code), not shipped UI.
// The chat column's width trial (chatWidth.ts, cx-ncc.107): one turn with prose, tool calls, a
// table and wide code, in each Debug Settings `agent.chatWidth`. Render it at 1440 and 1920.
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

/// The pane as the app pushes the Debug Settings `agent.chatWidth` with the theme.
const variant = (chatWidth: string, note: string): AgentPaneVariant => ({
  note,
  snapshot: rows,
  theme: { chatWidth },
});

export default agentPaneEntry({
  id: "agent-pane.chat-width",
  title: "Chat column width",
  area: "Agent pane",
  height: 900,
  covers: ["agent-session/acpmux/App.tsx#VirtualTranscript"],
  variants: {
    standard: variant("standard", "The default: the pane's width, at least 720px, to an 800px cap, for everything."),
    wide: variant("wide", 'Debug Settings chat width "wide": a 960px cap for everything.'),
    "wide-blocks": variant(
      "wideBlocks",
      'Debug Settings chat width "wideBlocks": code, tables and tools to 1120px; prose keeps the 800px measure.',
    ),
  },
});
