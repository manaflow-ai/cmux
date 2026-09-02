import { proxyClaudeMessages } from "../../../../services/coderouter/claudeProxy";
import { reportCoderouterFailure } from "../../../../services/coderouter/observability";

export const maxDuration = 300;

export async function POST(request: Request): Promise<Response> {
  try {
    return await proxyClaudeMessages(request, "count_tokens");
  } catch (error) {
    if (!request.signal.aborted) {
      reportCoderouterFailure("proxy_unhandled", error, {
        provider: "claude",
        surface: "count_tokens",
      });
    }
    return Response.json(
      { error: "coderouter_unavailable" },
      { status: 503, headers: { "cache-control": "no-store" } },
    );
  }
}
