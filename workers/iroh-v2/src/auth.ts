import { z } from "zod";
import { readBoundedBody } from "./boundary";
import { identifier, type Identity } from "./contracts/common";
import { OperationError } from "./errors";

export interface StackConfiguration {
  readonly environment: string;
  readonly apiURL: string;
  readonly projectId: string;
  readonly publishableKey: string;
  readonly serverKey?: string;
}

export interface VerifiedAuthority {
  readonly environment: string;
  readonly projectId: string;
  readonly teamId: string;
  readonly userId: string;
  readonly verifiedAt: number;
}

const UserSchema = z.object({ id: identifier });
const TeamsSchema = z.object({ items: z.array(z.object({ id: identifier })).max(4096) });
const PermissionsSchema = z.object({ items: z.array(z.object({ id: identifier, team_id: identifier, user_id: identifier })).max(4096) });
type Fetch = (input: string, init: RequestInit) => Promise<Response>;

/** Stack work is bounded even before the claimed user has been verified. */
export class StackAuthority {
  private inFlight = 0;

  constructor(
    private readonly configuration: StackConfiguration,
    private readonly request: Fetch = (input, init) => fetch(input, init),
    private readonly maxConcurrent = 8,
  ) {
    const origin = new URL(configuration.apiURL);
    if (origin.protocol !== "https:" || origin.username || origin.password || origin.search || origin.hash || origin.pathname !== "/") {
      throw new Error("Stack authority requires a configured HTTPS origin");
    }
    if (!configuration.projectId || !configuration.publishableKey) throw new Error("Stack authority is not configured");
    if (!Number.isSafeInteger(maxConcurrent) || maxConcurrent < 1) throw new Error("Invalid authentication work bound");
  }

  /** Called for issuance, never for an ordinary ticket-authorized operation. */
  async verify(accessToken: string, identity: Pick<Identity, "environment" | "projectId" | "teamId" | "userId">, now: number): Promise<VerifiedAuthority> {
    if (!accessToken || accessToken.length > 8192 || /[\r\n]/.test(accessToken)) throw new OperationError("unauthorized", 401);
    if (identity.environment !== this.configuration.environment || identity.projectId !== this.configuration.projectId) {
      throw new OperationError("environment_mismatch", 403);
    }
    if (this.inFlight >= this.maxConcurrent) throw new OperationError("upstream_unavailable", 503, true, 1000);
    this.inFlight++;
    try {
      const headers = {
        "x-stack-access-type": "client", "x-stack-project-id": this.configuration.projectId,
        "x-stack-publishable-client-key": this.configuration.publishableKey, "x-stack-access-token": accessToken,
      };
      // Verify the selected team explicitly. No fallback team or claimed user ID
      // can create authority or a user rate bucket.
      const me = UserSchema.parse(await this.get("/api/v1/users/me", headers));
      if (me.id !== identity.userId) throw new OperationError("identity_mismatch", 403);
      const teams = TeamsSchema.parse(await this.get("/api/v1/teams?user_id=me", headers));
      if (!teams.items.some(team => team.id === identity.teamId)) throw new OperationError("team_access_revoked", 403);
      return { environment: identity.environment, projectId: identity.projectId, teamId: identity.teamId, userId: me.id, verifiedAt: now };
    } catch (error) {
      if (error instanceof OperationError) throw error;
      // An unavailable or malformed provider response must not sign the user out.
      throw new OperationError("upstream_unavailable", 503, true, 2000);
    } finally { this.inFlight--; }
  }

  /** Management is uncommon and must use current Stack authority. */
  async canManageTeam(authority: VerifiedAuthority): Promise<boolean> {
    if (authority.environment !== this.configuration.environment || authority.projectId !== this.configuration.projectId) {
      throw new OperationError("environment_mismatch", 403);
    }
    const query = new URLSearchParams({ team_id: authority.teamId, user_id: authority.userId, permission_id: "$update_team", recursive: "true" });
    const response = await this.serverRead("/api/v1/team-permissions?" + query);
    const parsed = PermissionsSchema.safeParse(response);
    if (!parsed.success) throw new OperationError("upstream_unavailable", 503, true, 2000);
    return parsed.data.items.some(permission => permission.id === "$update_team" && permission.team_id === authority.teamId && permission.user_id === authority.userId);
  }

  async verifyTeamMember(teamId: string, userId: string): Promise<boolean> {
    identifier.parse(teamId); identifier.parse(userId);
    const response = await this.serverRead("/api/v1/teams?" + new URLSearchParams({ user_id: userId }));
    const parsed = TeamsSchema.safeParse(response);
    if (!parsed.success) throw new OperationError("upstream_unavailable", 503, true, 2000);
    return parsed.data.items.some(team => team.id === teamId);
  }

  private async serverRead(path: string): Promise<unknown> {
    if (!this.configuration.serverKey || this.inFlight >= this.maxConcurrent) throw new OperationError("upstream_unavailable", 503, true, 2000);
    this.inFlight++;
    try {
      return await this.get(path, {
        "x-stack-access-type": "server", "x-stack-project-id": this.configuration.projectId,
        "x-stack-secret-server-key": this.configuration.serverKey,
      }, true);
    } finally { this.inFlight--; }
  }

  private async get(path: string, headers: Record<string, string>, server = false): Promise<unknown> {
    let response: Response;
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), 5000);
    try {
      response = await this.request(new URL(path, this.configuration.apiURL).href, {
        headers, signal: controller.signal, redirect: "manual",
      });
    } catch (error) {
      console.log(JSON.stringify({ event: "iroh.stack.fetch_failed", path, error: error instanceof Error ? error.name : "unknown", message: error instanceof Error ? error.message.slice(0, 160) : "unknown" }));
      throw new OperationError("upstream_unavailable", 503, true, 2000);
    } finally { clearTimeout(timeout); }
    if (!response.ok) {
      console.log(JSON.stringify({ event: "iroh.stack.response_failed", path, status: response.status }));
      await response.body?.cancel();
      // A bad server credential is an outage, never evidence against this user.
      if (!server && response.status === 401) throw new OperationError("unauthorized", 401);
      if (!server && response.status === 403) throw new OperationError("team_access_revoked", 403);
      throw new OperationError("upstream_unavailable", 503, true, 2000);
    }
    try { return await readBoundedBody(response, 512 * 1024); }
    catch { throw new OperationError("upstream_unavailable", 503, true, 2000); }
  }
}
