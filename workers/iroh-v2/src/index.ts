import { errorResponse, httpFailure } from "./boundary";
import { runtime, type Environment } from "./environment";
import { routeControl, objectName } from "./routing";
import { unwrap } from "./user-usage-object";
export { TeamControl } from "./team-control";
export { UserUsage } from "./user-usage-object";

export default {
  async fetch(request, env): Promise<Response> {
    const started = Date.now();
    let response: Response;
    try {
      const services = runtime(env);
      response = await routeControl(request, {
        ...services, ticketKeys: services.keys, now: () => Math.floor(Date.now() / 1000),
        chargeOpen: async userId => { unwrap(await env.USER_USAGE.getByName(objectName(services.environment, services.projectId, userId)).consume(userId, "control.socket")); },
        dispatchTeam: (teamId, forwarded) => env.TEAM_CONTROL.getByName(objectName(services.environment, services.projectId, teamId)).fetch(forwarded),
      });
    } catch (error) {
      const failure = errorResponse(error, "unidentified").failure;
      console.log(JSON.stringify({ event: "iroh.http.failure", environment: env.ENVIRONMENT, code: failure.code, status: failure.status, retryable: failure.retryable }));
      response = httpFailure(error);
    }
    console.log(JSON.stringify({ event: "iroh.http.response", environment: env.ENVIRONMENT, status: response.status, durationMs: Date.now() - started }));
    return response;
  },
} satisfies ExportedHandler<Environment>;
