import { proxyOpenCodeRequest } from "../../../../../../../services/coderouter/opencodeProxy";

export const maxDuration = 1_800;

type Context = {
  readonly params: Promise<{
    readonly providerId: string;
    readonly path: string[];
  }>;
};

async function proxy(request: Request, context: Context): Promise<Response> {
  try {
    const params = await context.params;
    return await proxyOpenCodeRequest(request, params.providerId, params.path);
  } catch {
    return Response.json({ error: "coderouter_unavailable" }, { status: 503 });
  }
}

export const GET = proxy;
export const POST = proxy;
