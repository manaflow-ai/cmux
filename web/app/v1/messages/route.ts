import { proxyClaudeMessages } from "../../../services/coderouter/claudeProxy";
import { reportCoderouterFailure } from "../../../services/coderouter/observability";

export const maxDuration = 1_800;

export async function POST(request: Request): Promise<Response> {
  try {
    return await proxyClaudeMessages(request);
  } catch (error) {
    // A caller that hung up is not a plane failure; everything else is
    // reported with its real cause before the neutral 503 goes out.
    if (!request.signal.aborted) {
      reportCoderouterFailure("proxy_unhandled", error, {
        provider: "claude",
        surface: "messages",
      });
    }
    return Response.json(
      { error: "coderouter_unavailable" },
      { status: 503, headers: { "cache-control": "no-store" } },
    );
  }
}
