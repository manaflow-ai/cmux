// l10n-allow-file: gallery fixtures (sample prompts and harness errors), not shipped UI.
// A turn whose harness retries a model request that failed (Leo, 2026-11-03, on "Thinking 7m 49s"
// from a chat whose model gateway was down: "i feel like this mac session just keeps "thinking""):
// acpmux logs each retry as `turn_retrying` (hub/turn_retry.rs), and the live line says the model
// cannot be reached, with the retry's count and the harness's error, never "Thinking" and with no
// clock (Thinking.tsx `retryParts`). It keeps the line's box, so nothing moves when it starts or
// ends. A retry that runs out ends the turn failed, on the error card with Retry (TurnRows.tsx).
// The same chat runs live in the mock daemon: `?mock&session=mock-model-retry`.
import { agentPaneEntry } from "../../../gallery/format";
import { chat, row, summary, user } from "../../../gallery/fixtures/acpmux";
import { TURN_RETRY, type AcpmuxTurnRetry } from "../model";

const prompt = "Fix the flaky upload test";

/// A running turn, sent 7m 49s ago, whose harness retries its model request now.
const retrying = (retry: AcpmuxTurnRetry) =>
  chat([user(prompt, 7 + 49 / 60), row("typing", 7.4, { id: TURN_RETRY, retry })], { isWorking: true });

export default agentPaneEntry({
  id: "agent-pane.turn-retry",
  title: "Live line: model retry",
  area: "Agent pane",
  height: 280,
  covers: ["agent-session/acpmux/conversation/Thinking.tsx#Thinking"],
  keywords: ["retry", "api_retry", "unreachable", "gateway", "503", "thinking", "overloaded"],
  variants: {
    retrying: {
      note: "Claude Code retries a model request with no error named: Can't reach the model · retrying (7 of 10), calm, no sweep and no clock.",
      snapshot: retrying({ attempt: 7, maxRetries: 10 }),
    },
    "retrying-with-error": {
      note: "Leo's chat: the gateway answered 503 server_error on each try. The error follows the count, muted, and gives way first on a narrow pane.",
      snapshot: retrying({ attempt: 7, maxRetries: 10, errorStatus: 503, error: "server_error" }),
    },
    "retrying-busy": {
      note: "A rate limit or an overloaded model (429, 529): The model is busy, not unreachable.",
      snapshot: retrying({ attempt: 2, maxRetries: 10, errorStatus: 529, error: "overloaded_error" }),
    },
    "given-up": {
      note: "The tenth retry failed too: the turn ends failed on the error card, with Retry, instead of a silent Thinking.",
      snapshot: chat([
        user(prompt, 12),
        summary(0.2, { status: "failed", durationMs: 712_000, error: "API Error: Connection error.", prompt }),
      ]),
    },
  },
});
