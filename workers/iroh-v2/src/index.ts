import { errorResponse, httpFailure } from "./boundary";
import { runtime, type Environment } from "./environment";
import { routeControl, objectName } from "./routing";
import { unwrap } from "./user-usage-object";
import { observe } from "./observability";
import { routeDashboard } from "./dashboard-routing";
import { VmChangedRequestSchema, WorkspacePublishRequestSchema } from "./contracts/workspaces";
export { TeamControl } from "./team-control";
export { UserUsage } from "./user-usage-object";

export default {
  async fetch(request, env, ctx): Promise<Response> {
    const started = Date.now();
    let response: Response;
    try {
      const services = runtime(env);
      const shared = {
        ...services, now: () => Math.floor(Date.now() / 1000),
        observe: (event: { event: string; requestId: string; code: string; status: number }) => observe(ctx, env, { environment: env.ENVIRONMENT, ...event }),
        dispatchTeam: (teamId: string, forwarded: Request) => env.TEAM_CONTROL.getByName(objectName(services.environment, services.projectId, teamId)).fetch(forwarded),
      };
      if (new URL(request.url).pathname === "/v2/workspace/publish") {
        if (request.method !== "POST" || !env.WORKSPACE_PUBLISHER_SECRET
          || request.headers.get("x-cmux-workspace-publisher-secret") !== env.WORKSPACE_PUBLISHER_SECRET) {
          response = new Response(JSON.stringify({ error: "unauthorized" }), { status: 401, headers: { "content-type": "application/json" } });
        } else {
          const body = await request.json();
          const publish = WorkspacePublishRequestSchema.parse(body);
          const stub = env.TEAM_CONTROL.getByName(objectName(services.environment, services.projectId, publish.teamId));
          response = await stub.fetch(new Request("https://iroh-v2.internal/workspace/publish", {
            method: "POST",
            headers: { "content-type": "application/json", "x-cmux-workspace-publisher-secret": env.WORKSPACE_PUBLISHER_SECRET },
            body: JSON.stringify(publish),
          }));
        }
      } else if (new URL(request.url).pathname === "/v2/vm/changed") {
        if (request.method !== "POST" || !env.WORKSPACE_PUBLISHER_SECRET
          || request.headers.get("x-cmux-workspace-publisher-secret") !== env.WORKSPACE_PUBLISHER_SECRET) {
          response = new Response(JSON.stringify({ error: "unauthorized" }), { status: 401, headers: { "content-type": "application/json" } });
        } else {
          const change = VmChangedRequestSchema.parse(await request.json());
          const stub = env.TEAM_CONTROL.getByName(objectName(services.environment, services.projectId, change.teamId));
          response = await stub.fetch(new Request("https://iroh-v2.internal/vm/changed", {
            method: "POST",
            headers: { "content-type": "application/json", "x-cmux-workspace-publisher-secret": env.WORKSPACE_PUBLISHER_SECRET },
            body: JSON.stringify(change),
          }));
        }
      } else {
        response = new URL(request.url).pathname.startsWith("/v2/dashboard/") ? await routeDashboard(request, {
          ...shared,
          charge: async (userId, operation) => { unwrap(await env.USER_USAGE.getByName(objectName(services.environment, services.projectId, userId)).consume(userId, operation)); },
        }) : await routeControl(request, {
          ...services, ticketKeys: services.keys, now: () => Math.floor(Date.now() / 1000),
          observe: event => observe(ctx, env, { environment: env.ENVIRONMENT, ...event }),
          chargeOpen: async userId => { unwrap(await env.USER_USAGE.getByName(objectName(services.environment, services.projectId, userId)).consume(userId, "control.socket")); },
          dispatchTeam: (teamId, forwarded) => env.TEAM_CONTROL.getByName(objectName(services.environment, services.projectId, teamId)).fetch(forwarded),
        });
      }
    } catch (error) {
      const failure = errorResponse(error, "unidentified").failure;
      observe(ctx, env, { event: "iroh.http.failure", environment: env.ENVIRONMENT, path: new URL(request.url).pathname, code: failure.code, status: failure.status, retryable: failure.retryable });
      response = httpFailure(error);
    }
    observe(ctx, env, { event: "iroh.http.response", environment: env.ENVIRONMENT, path: new URL(request.url).pathname, status: response.status, durationMs: Date.now() - started });
    return response;
  },
} satisfies ExportedHandler<Environment>;
