import { errorResponse, httpFailure } from "./boundary";
import { runtime, type Environment } from "./environment";
import { routeControl, objectName } from "./routing";
import { unwrap } from "./user-usage-object";
import { observe } from "./observability";
import { routeDashboard } from "./dashboard-routing";
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
      response = new URL(request.url).pathname.startsWith("/v2/dashboard/") ? await routeDashboard(request, {
        ...shared,
        charge: async (userId, operation) => { unwrap(await env.USER_USAGE.getByName(objectName(services.environment, services.projectId, userId)).consume(userId, operation)); },
      }) : await routeControl(request, {
        ...services, ticketKeys: services.keys, now: () => Math.floor(Date.now() / 1000),
        observe: event => observe(ctx, env, { environment: env.ENVIRONMENT, ...event }),
        chargeOpen: async userId => { unwrap(await env.USER_USAGE.getByName(objectName(services.environment, services.projectId, userId)).consume(userId, "control.socket")); },
        dispatchTeam: (teamId, forwarded) => env.TEAM_CONTROL.getByName(objectName(services.environment, services.projectId, teamId)).fetch(forwarded),
      });
    } catch (error) {
      const failure = errorResponse(error, "unidentified").failure;
      observe(ctx, env, { event: "iroh.http.failure", environment: env.ENVIRONMENT, path: new URL(request.url).pathname, code: failure.code, status: failure.status, retryable: failure.retryable });
      response = httpFailure(error);
    }
    observe(ctx, env, { event: "iroh.http.response", environment: env.ENVIRONMENT, path: new URL(request.url).pathname, status: response.status, durationMs: Date.now() - started });
    return response;
  },
} satisfies ExportedHandler<Environment>;
