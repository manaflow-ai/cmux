import { z } from "zod";
import { readBoundedBody } from "./boundary";
import { identifier, type Identity } from "./contracts/common";
import { OperationError } from "./errors";

export interface StackConfiguration {
  readonly environment: string;
  readonly apiURL: string;
  readonly projectId: string;
  readonly publishableKey: string;
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
  async verify(accessToken: string, identity: Identity, now: number): Promise<VerifiedAuthority> {
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

  private async get(path: string, headers: Record<string, string>): Promise<unknown> {
    let response: Response;
    try {
      response = await this.request(new URL(path, this.configuration.apiURL).href, {
        headers, signal: AbortSignal.timeout(5000), redirect: "error",
      });
    } catch { throw new OperationError("upstream_unavailable", 503, true, 2000); }
    if (!response.ok) {
      await response.body?.cancel();
      if (response.status === 401) throw new OperationError("unauthorized", 401);
      if (response.status === 403) throw new OperationError("team_access_revoked", 403);
      throw new OperationError("upstream_unavailable", 503, true, 2000);
    }
    try { return await readBoundedBody(response, 512 * 1024); }
    catch { throw new OperationError("upstream_unavailable", 503, true, 2000); }
  }
}
