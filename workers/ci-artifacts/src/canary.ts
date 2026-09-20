import broker, { ArtifactImport } from "./index";
import { canaryAllowed } from "./canary-route";

export { ArtifactImport };

// A separately deployed canary, never the production Worker entrypoint.
export default {
  async fetch(request: Request, env: Env & { CANARY_ENABLED?: string; CANARY_EXPIRES_AT?: string; CANARY_ACCESS_TOKEN?: string }): Promise<Response> {
    if (!canaryAllowed(request, env.CANARY_ENABLED, env.CANARY_EXPIRES_AT, env.CANARY_ACCESS_TOKEN)) {
      return new Response("Not found", { status: 404, headers: { "Cache-Control": "no-store" } });
    }
    return broker.fetch(request, env);
  },
} satisfies ExportedHandler<Env & { CANARY_ENABLED?: string; CANARY_EXPIRES_AT?: string; CANARY_ACCESS_TOKEN?: string }>;
