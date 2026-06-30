import { CollaborationSessionObject } from "./session";
import { collaborationFetch } from "./handler";

export { CollaborationSessionObject };

export interface Env {
  COLLABORATION_SESSIONS: DurableObjectNamespace<CollaborationSessionObject>;
}

export default {
  async fetch(request: Request, env: Env): Promise<Response> {
    return collaborationFetch(request, env);
  },
} satisfies ExportedHandler<Env>;
