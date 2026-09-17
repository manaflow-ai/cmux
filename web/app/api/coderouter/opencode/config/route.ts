import { openCodeClientConfig } from "../../../../../services/coderouter/opencodeProxy";


export async function GET(request: Request): Promise<Response> {
  try {
    return await openCodeClientConfig(request);
  } catch {
    return Response.json({ error: "coderouter_unavailable" }, { status: 503 });
  }
}
