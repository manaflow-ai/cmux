import { handleScopedConnectivitySync } from "../../../../../services/connectivity/routeHandler";


export async function POST(request: Request): Promise<Response> {
  return handleScopedConnectivitySync(request);
}
