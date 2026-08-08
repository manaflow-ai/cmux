import { proxyCodexRequest } from "../../../services/coderouter/codexProxy";

export const maxDuration = 1_800;

export async function POST(request: Request): Promise<Response> {
  try {
    return await proxyCodexRequest(request);
  } catch {
    return Response.json(
      { error: "coderouter_unavailable" },
      { status: 503, headers: { "cache-control": "no-store" } },
    );
  }
}
