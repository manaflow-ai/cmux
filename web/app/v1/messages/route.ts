import { anthropicError, proxyClaudeMessages } from "../../../services/coderouter/claudeProxy";
import { withCoderouterRoute } from "../../../services/coderouter/requestTelemetry";

export const maxDuration = 1_800;

export const POST = withCoderouterRoute(
  {
    surface: "messages",
    route: "/v1/messages",
    unavailable: () => anthropicError(503, "api_error", "coderouter is temporarily unavailable. Retry shortly."),
  },
  (request) => proxyClaudeMessages(request),
);
