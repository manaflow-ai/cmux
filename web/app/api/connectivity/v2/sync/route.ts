import { handleConnectivitySync } from "../../../../../services/connectivity/routeHandler";


export async function POST(request: Request): Promise<Response> {
  return handleConnectivitySync(request);
}
