import { anthropicError, proxyClaudeCountTokens } from "../../../../services/coderouter/claudeProxy";
import { withCoderouterRoute } from "../../../../services/coderouter/requestTelemetry";

export const maxDuration = 60;

export const POST = withCoderouterRoute(
  {
    surface: "count_tokens",
    route: "/v1/messages/count_tokens",
    unavailable: () => anthropicError(503, "api_error", "coderouter is temporarily unavailable. Retry shortly."),
  },
  (request) => proxyClaudeCountTokens(request),
);
