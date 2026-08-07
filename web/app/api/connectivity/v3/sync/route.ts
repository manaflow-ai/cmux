import { handleScopedConnectivitySync } from "../../../../../services/connectivity/routeHandler";

export const runtime = "nodejs";
export const dynamic = "force-dynamic";

export async function POST(request: Request): Promise<Response> {
  return handleScopedConnectivitySync(request);
}
