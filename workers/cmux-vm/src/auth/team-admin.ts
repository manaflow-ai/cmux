/**
 * Whether a team member is a team admin: Stack's `team_admin` team
 * permission, granted directly or through a containing permission
 * (`recursive=true`). The web app uses the same rule
 * (web/services/teams/permissions.ts). Asked only for API key management, so
 * it is not cached; any doubt is "not an admin".
 */
import { Context, Effect, Layer, Redacted, Schema } from "effect";
import type { TenantId, UserId } from "../lib/ids.ts";
import { IdentityUnavailable } from "./credentials.ts";

export const TEAM_ADMIN_PERMISSION = "team_admin";

export interface TeamAdminService {
  readonly isAdmin: (tenantId: TenantId, userId: UserId) => Effect.Effect<boolean, IdentityUnavailable>;
}

export class TeamAdmin extends Context.Tag("cmux-vm/TeamAdmin")<TeamAdmin, TeamAdminService>() {}

const PermissionsResponse = Schema.Struct({ items: Schema.Array(Schema.Struct({ id: Schema.String })) });

export function makeStackTeamAdmin(config: {
  readonly apiUrl: string;
  readonly projectId: string;
  readonly serverKey: Redacted.Redacted<string>;
  readonly fetch?: (request: Request) => Promise<Response>;
}): TeamAdminService {
  const origin = new URL(config.apiUrl);
  if (origin.protocol !== "https:" || origin.username || origin.password || origin.search || origin.hash || origin.pathname !== "/") {
    throw new Error("Stack API URL must be a bare HTTPS origin");
  }
  const send = config.fetch ?? ((request: Request) => fetch(request));
  const decode = Schema.decodeUnknown(PermissionsResponse);
  return {
    isAdmin: (tenantId, userId) =>
      Effect.tryPromise({
        try: async () => {
          const url = new URL("/api/v1/team-permissions", origin);
          url.searchParams.set("team_id", tenantId);
          url.searchParams.set("user_id", userId);
          url.searchParams.set("permission_id", TEAM_ADMIN_PERMISSION);
          url.searchParams.set("recursive", "true");
          const response = await send(
            new Request(url, {
              headers: {
                "x-stack-access-type": "server",
                "x-stack-project-id": config.projectId,
                "x-stack-secret-server-key": Redacted.value(config.serverKey),
                accept: "application/json",
              },
              redirect: "manual",
              signal: AbortSignal.timeout(5000),
            }),
          );
          if (!response.ok) {
            await response.body?.cancel();
            throw new Error(`stack ${response.status}`);
          }
          const body: unknown = await response.json();
          return body;
        },
        catch: () => new IdentityUnavailable({ reason: "stack" }),
      }).pipe(
        Effect.flatMap((body) => decode(body).pipe(Effect.mapError(() => new IdentityUnavailable({ reason: "stack-shape" })))),
        Effect.map((permissions) => permissions.items.some((permission) => permission.id === TEAM_ADMIN_PERMISSION)),
      ),
  };
}

export const stackTeamAdminLayer = (config: Parameters<typeof makeStackTeamAdmin>[0]): Layer.Layer<TeamAdmin> =>
  Layer.succeed(TeamAdmin, makeStackTeamAdmin(config));
