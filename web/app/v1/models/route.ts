import { proxyCodexModels } from "@/services/coderouter/codexProxy";
import {
  anthropicError,
  isAnthropicRequest,
  proxyClaudeModels,
} from "@/services/coderouter/claudeProxy";
import {
  coderouterUnavailable,
  withCoderouterRoute,
} from "@/services/coderouter/requestTelemetry";

export const maxDuration = 60;

// Anthropic clients (the SDK, Claude Code) always send `anthropic-version`;
// those get the Anthropic-shaped catalog for the team's Claude upstream.
// Every other caller keeps the Codex behaviour.
export const GET = withCoderouterRoute(
  {
    surface: "models",
    route: "/v1/models",
    unavailable: (request) =>
      isAnthropicRequest(request)
        ? anthropicError(503, "api_error", "coderouter is temporarily unavailable. Retry shortly.")
        : coderouterUnavailable(),
  },
  (request) => (isAnthropicRequest(request) ? proxyClaudeModels(request) : proxyCodexModels(request)),
);
