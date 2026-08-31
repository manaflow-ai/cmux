import { proxyClaudeMessages } from "../../../services/coderouter/claudeProxy";

export const maxDuration = 1_800;

export async function POST(request: Request): Promise<Response> {
  try {
    return await proxyClaudeMessages(request);
  } catch {
    return Response.json(
      { error: "coderouter_unavailable" },
      { status: 503, headers: { "cache-control": "no-store" } },
    );
  }
}
