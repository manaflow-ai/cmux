// l10n-allow-file: gallery fixtures (sample prompts, replies and code), not shipped UI.
// The transcript's looks (conversation/transcriptLook.ts, schemas/transcript-look/transcript-look.json;
// Leo, 2026-11-18: "esp the like... claude style, chatgpt/codex style, and "studio" style things"):
// one chat in each named look, and two token overrides on the cmux look, pushed as the app pushes
// `agentPane.display.transcriptLook` and `agentPane.display.transcriptTokens`. `cmux` is the chat as
// it drew before looks.
import { agentPaneEntry, type AgentPaneVariant } from "../../../gallery/format";
import { activity, assistant, chat, summary, tool, user } from "../../../gallery/fixtures/acpmux";
import { TRANSCRIPT_LOOKS, TRANSCRIPT_LOOK_KEY, TRANSCRIPT_TOKENS_KEY } from "./transcriptLook";

const REPLY = [
  "The fetch helper now retries transient failures with exponential backoff and full jitter, so a burst of 429s no longer fails the whole sync. Requests that are not safe to repeat still fail at once unless the caller passes a policy.",
  "",
  "- **GETs** retry `408`, `429` and gateway `5xx` errors, honoring `Retry-After`.",
  "- **POSTs** retry only with `retry: { attempts: 5 }`.",
  "",
  "```ts",
  "export async function withRetry<T>(run: (attempt: number) => Promise<T>, policy = DEFAULT_RETRY_POLICY): Promise<T> {",
  "  for (let attempt = 1; ; attempt += 1) {",
  "    try {",
  "      return await run(attempt);",
  "    } catch (error) {",
  "      if (attempt >= policy.attempts || !isTransient(error)) throw error;",
  "      await sleep(Math.min(policy.maxDelayMs, policy.baseDelayMs * 2 ** (attempt - 1)) * Math.random());",
  "    }",
  "  }",
  "}",
  "```",
].join("\n");

const rows = chat([
  user("Add retries with backoff to the fetch helper, and make sure POSTs never retry on their own", 9),
  activity(
    [
      tool("Read src/net/client.ts", "read", "completed"),
      tool("Search for parseError", "search", "completed"),
      tool("Edit src/net/retry.ts", "edit", "completed"),
      tool("bun test src/net", "execute", "completed", { command: "bun test src/net", output: "41 pass\n0 fail" }),
    ],
    8.5,
  ),
  assistant(REPLY, 8),
  summary(8, { status: "completed", durationMs: 48_000, toolCount: 4 }),
  user("Great. Now log each retry with its attempt number", 3),
  activity([tool("Edit src/net/retry.ts", "edit", "completed")], 2.5),
  assistant("Done: every retry logs `retrying GET /sync after 412 ms (attempt 2 of 5)`.", 2),
  summary(2, { status: "completed", durationMs: 9_000, toolCount: 1 }),
]);

const LOOK = TRANSCRIPT_LOOK_KEY;
const TOKENS = TRANSCRIPT_TOKENS_KEY;

const variant = (display: Record<string, unknown>, note: string): AgentPaneVariant => ({
  note,
  snapshot: rows,
  display,
});
const lookVariant = (name: string, reference: string): AgentPaneVariant => {
  const look = TRANSCRIPT_LOOKS.find((value) => value.name === name)!;
  const note = `${look.title}: ${look.description} Reference: cmux-design-references ${reference}.`;
  return variant({ [LOOK]: name }, note);
};

export default agentPaneEntry({
  id: "agent-pane.transcript-look",
  title: "Transcript looks",
  area: "Agent pane",
  height: 900,
  covers: ["agent-session/acpmux/VirtualTranscript.tsx#VirtualTranscript"],
  variants: {
    cmux: variant({}, "cmux, the default: no token set, the chat as it draws today."),
    // A named look's note is its JSON title and description (so it never drifts from the data) and its
    // reference capture in cmux-design-references, outside this repo: other apps' screenshots are never
    // copied in.
    claude: lookVariant("claude", "apps/claude/live/transcript-tool-rows-and-task-list.png"),
    codex: lookVariant("codex", "apps/codex/web/review-workspace-dark.webp"),
    studio: lookVariant("studio", "the Studio app's live/transcript-expanded-tool-history.png"),
    "plain-prompt": variant(
      { [TOKENS]: { "userMessage.style": "plain", timestamps: "always" } },
      "cmux with a plain prompt (a 2 pt leading rule, no fill, left) and times always shown.",
    ),
    "part-type": variant(
      {
        [TOKENS]: {
          "reply.font": "serif",
          "reply.fontSize": 16,
          "userMessage.font": "mono",
          "userMessage.fontSize": 13,
        },
      },
      "cmux with each part's own type: replies in the system serif at 16, your messages in the code face at 13 (reply.font, reply.fontSize, userMessage.font, userMessage.fontSize).",
    ),
    "claude-own-font": variant(
      { [LOOK]: "claude", "agentPane.display.font.preset": "system", "agentPane.display.font.size": 14 },
      "Claude with your own Agent Chat font and size set: yours win over the look's serif replies and part sizes.",
    ),
    "card-tools": variant(
      { [LOOK]: "claude", [TOKENS]: { toolCards: "card", "toolCard.radius": 10 } },
      "Claude with each tool run drawn on a card (toolCards card, 10 pt corners).",
    ),
  },
});
