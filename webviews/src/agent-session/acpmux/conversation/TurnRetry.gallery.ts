// l10n-allow-file: gallery fixtures (sample prompts and harness errors), not shipped UI.
// A turn whose harness retries a model request that failed (Leo, 2026-11-03, on "Thinking 7m 49s"
// from a chat whose model gateway was down: "i feel like this mac session just keeps "thinking""):
// acpmux logs each retry as `turn_retrying` (hub/turn_retry.rs), and the live line says, in one
// short line that stays the same from one retry to the next, that the model API is unavailable;
// what failed, the count and the harness's error are its tooltip (Thinking.tsx `retryParts`; Leo,
// 2026-11-26, on "Can't reach ... · retrying (1 of 14) · retrying now · 502 ser...": "this is
// really really bad"). A retry that goes through within the shared bound draws nothing. It keeps
// the line's box, so nothing moves when it starts or ends. A retry that runs out ends the turn
// failed, on the error card with Retry (TurnRows.tsx).
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
      note: "Claude Code retries a model request with no error named: Model API unavailable, retrying…, calm, no count, no clock.",
      snapshot: retrying({ attempt: 7, maxRetries: 10 }),
    },
    "retrying-with-error": {
      note: "Leo's chat, 2026-11-26: the gateway answered 502 server_error on the first of 14 tries. One short line; the count and the 502 only in the tooltip.",
      snapshot: retrying({ attempt: 1, maxRetries: 14, errorStatus: 502, error: "server_error" }),
    },
    "retrying-dns": {
      note: "acpmux classified a DNS failure of api.anthropic.com: the same short line; the host only in the tooltip, so nothing cuts off.",
      snapshot: retrying({ attempt: 3, maxRetries: 14, cause: "dns", host: "api.anthropic.com", line: "unavailable" }),
    },
    "retrying-busy": {
      note: "A rate limit or an overloaded model (429, 529): Waiting for capacity, at once; the count and the 529 only in the tooltip.",
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
