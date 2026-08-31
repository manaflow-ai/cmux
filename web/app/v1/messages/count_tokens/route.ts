import { proxyClaudeMessages } from "../../../../services/coderouter/claudeProxy";

export const maxDuration = 300;

export async function POST(request: Request): Promise<Response> {
  try {
    return await proxyClaudeMessages(request, "count_tokens");
  } catch {
    return Response.json(
      { error: "coderouter_unavailable" },
      { status: 503, headers: { "cache-control": "no-store" } },
    );
  }
}
