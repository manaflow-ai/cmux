import broker, { ArtifactImport } from "./index";
import { handleCanaryRequest, type CanaryConfiguration } from "./canary-route";

export { ArtifactImport };

// A separately deployed canary, never the production Worker entrypoint.
export default {
  async fetch(request: Request, env: Env & CanaryConfiguration): Promise<Response> {
    return handleCanaryRequest(request, env, () => broker.fetch(request, env));
  },
} satisfies ExportedHandler<Env & CanaryConfiguration>;
