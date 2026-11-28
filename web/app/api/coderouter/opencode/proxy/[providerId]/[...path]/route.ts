import { proxyOpenCodeRequest } from "../../../../../../../services/coderouter/opencodeProxy";
import { coderouterControlRoute } from "../../../../../../../services/coderouter/requestTelemetry";

export const maxDuration = 1_800;

type Context = {
  readonly params: Promise<{
    readonly providerId: string;
    readonly path: string[];
  }>;
};

const proxy = coderouterControlRoute<Context>(
  "opencode_proxy",
  "/api/coderouter/opencode/proxy/[providerId]/[...path]",
  async (request, context) => {
    const params = await context.params;
    return proxyOpenCodeRequest(request, params.providerId, params.path);
  },
);

export const GET = proxy;
export const POST = proxy;
