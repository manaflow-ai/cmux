/**
 * Agent keys and per-VM client sessions.
 *
 * An agent key lets a cloud agent start and clean up its own sandboxes without
 * holding a team credential: it reaches only VMs labelled cmux.agent=<its id>
 * (every VM it creates gets that label), it has a live-VM count and an
 * estimated USD/h budget, and it expires. When it expires or is revoked, the
 * service deletes its VMs and their client sessions.
 *
 * A client session is a provider access token for exactly one VM and one Linux
 * user, for clients that talk to the provider directly (SDK, SSH proxy). It is
 * revoked when the VM is deleted. The team's provider key is never returned.
 */
import { HttpApiEndpoint, HttpApiGroup, HttpApiSchema, OpenApi } from "@effect/platform";
import { Schema } from "effect";
import { AGENT_DEFAULTS, AGENT_LIMITS, AGENT_SCOPES } from "../domain/agents.ts";
import { ReportedScope, Scope } from "../domain/scopes.ts";
import { BadRequest, Forbidden, NotFound, QuotaExceeded, ServiceUnavailable } from "../errors.ts";
import { ApiKeyId, ClientSessionId } from "../lib/ids.ts";
import { GroupTeamHeaders } from "./common.ts";

const AgentScope = Scope.pipe(Schema.filter((scope) => AGENT_SCOPES.includes(scope), { message: () => `agent keys hold only ${AGENT_SCOPES.join(", ")}` }));

export class CreateAgentKeyRequest extends Schema.Class<CreateAgentKeyRequest>("CreateAgentKeyRequest")({
  name: Schema.String.pipe(Schema.minLength(1), Schema.maxLength(200)),
  /** Default vm:read, vm:write, vm:exec; never more than the issuer holds. */
  scopes: Schema.optional(Schema.Array(AgentScope).pipe(Schema.minItems(1), Schema.maxItems(AGENT_SCOPES.length))),
  ttlSeconds: Schema.optional(Schema.Int.pipe(Schema.between(AGENT_LIMITS.minTtlSeconds, AGENT_LIMITS.maxTtlSeconds))),
  maxVms: Schema.optional(Schema.Int.pipe(Schema.between(1, AGENT_LIMITS.maxVms))),
  maxUsdPerHour: Schema.optional(Schema.Number.pipe(Schema.greaterThan(0), Schema.lessThanOrEqualTo(AGENT_LIMITS.maxUsdPerHour))),
}) {}

export class CreatedAgentKey extends Schema.Class<CreatedAgentKey>("CreatedAgentKey")({
  id: ApiKeyId,
  name: Schema.String,
  /** The full key. Shown only in this response; give it to the agent and nobody else. */
  key: Schema.String,
  scopes: Schema.Array(ReportedScope),
  /** Every VM the key creates carries these labels, and it reaches no VM without them. */
  labels: Schema.Record({ key: Schema.String, value: Schema.String }),
  createdAt: Schema.String,
  expiresAt: Schema.String,
  maxVms: Schema.Int,
  maxUsdPerHour: Schema.Number,
}) {}

export class CreateClientSessionRequest extends Schema.Class<CreateClientSessionRequest>("CreateClientSessionRequest")({
  /** The Linux user the token may act as. Default ubuntu (uid 1000 on the base images). */
  linuxUser: Schema.optional(Schema.String.pipe(Schema.pattern(/^[a-z_][a-z0-9_-]{0,31}$/u))),
}) {}

export class ClientSession extends Schema.Class<ClientSession>("ClientSession")({
  id: ClientSessionId,
  vmId: Schema.String,
  /** The provider access token. Shown only in this response. Valid until the VM is deleted or the session revoked. */
  token: Schema.String,
  /** The provider's id of this VM; the token is used with it directly. */
  providerVmId: Schema.String,
  linuxUser: Schema.String,
  /** Provider API origin for SDK clients: `new Freestyle({ identityAccessToken: token, baseUrl })`. */
  apiBaseUrl: Schema.String,
  /** Provider SSH proxy: `ssh <user>@<host>` with the token as the password. */
  ssh: Schema.Struct({ host: Schema.String, user: Schema.String }),
  createdAt: Schema.String,
}) {}

/** A live client session as listed: everything but the token, which is shown once at creation. */
export class ClientSessionSummary extends Schema.Class<ClientSessionSummary>("ClientSessionSummary")({
  id: ClientSessionId,
  vmId: Schema.String,
  linuxUser: Schema.String,
  createdAt: Schema.String,
}) {}

export class ClientSessionList extends Schema.Class<ClientSessionList>("ClientSessionList")({
  sessions: Schema.Array(ClientSessionSummary),
}) {}

const AgentKeyPath = Schema.Struct({ keyId: Schema.String });
const VmPath = Schema.Struct({ vmId: Schema.String });
const SessionPath = Schema.Struct({ vmId: Schema.String, sessionId: Schema.String });

/** Endpoints without the Authentication middleware; src/api.ts applies it. */
export class AgentsGroupDefinition extends HttpApiGroup.make("agents")
  .add(
    HttpApiEndpoint.post("createAgentKey", "/v1/agent-keys")
      .setPayload(CreateAgentKeyRequest)
      .setHeaders(GroupTeamHeaders)
      .addSuccess(CreatedAgentKey, { status: 201 })
      .addError(BadRequest)
      .addError(Forbidden)
      .addError(QuotaExceeded)
      .addError(ServiceUnavailable)
      .annotateContext(
        OpenApi.annotations({
          summary: "Issue an agent key",
          description:
            `Issue an agent key. Requires the vm:write scope, from a credential that is not itself an agent key or limited to specific resources. ` +
            `The key reaches only VMs labelled cmux.agent=<its id> (plus any labels the issuer is confined to); every VM it creates gets those labels. ` +
            `Defaults: scopes ${AGENT_SCOPES.join(", ")}, ttlSeconds ${AGENT_DEFAULTS.ttlSeconds} (at most ${AGENT_LIMITS.maxTtlSeconds}, never past the issuer's expiry), ` +
            `maxVms ${AGENT_DEFAULTS.maxVms} (at most ${AGENT_LIMITS.maxVms}), maxUsdPerHour ${AGENT_DEFAULTS.maxUsdPerHour} (at most ${AGENT_LIMITS.maxUsdPerHour}). ` +
            "When it expires or is revoked, its VMs and their client sessions are deleted within minutes.",
        }),
      ),
  )
  .add(
    HttpApiEndpoint.del("revokeAgentKey", "/v1/agent-keys/:keyId")
      .setPath(AgentKeyPath)
      .setHeaders(GroupTeamHeaders)
      .addSuccess(HttpApiSchema.NoContent)
      .addError(NotFound)
      .addError(QuotaExceeded)
      .addError(ServiceUnavailable)
      .annotateContext(
        OpenApi.annotations({
          summary: "Revoke an agent key and delete its VMs",
          description:
            "Revoke an agent key at once, then delete its VMs and their client sessions (the background cleanup finishes anything left). " +
            "Allowed for the credential that issued it, an admin key or team admin, and the agent key itself. Anything else is 404.",
        }),
      ),
  )
  .add(
    HttpApiEndpoint.post("createClientSession", "/v1/vms/:vmId/client-session")
      .setPath(VmPath)
      .setPayload(CreateClientSessionRequest)
      .setHeaders(GroupTeamHeaders)
      .addSuccess(ClientSession, { status: 201 })
      .addError(BadRequest)
      .addError(NotFound)
      .addError(QuotaExceeded)
      .addError(ServiceUnavailable)
      .annotateContext(
        OpenApi.annotations({
          summary: "Mint a provider token for one VM",
          description:
            "Mint a provider access token scoped to this VM and one Linux user. Requires the vm:exec scope. The token works only on this VM, " +
            "is shown once, and is revoked when the VM is deleted or the session is revoked. Another tenant's or another agent's VM is 404.",
        }),
      ),
  )
  .add(
    HttpApiEndpoint.get("listClientSessions", "/v1/vms/:vmId/client-sessions")
      .setPath(VmPath)
      .setHeaders(GroupTeamHeaders)
      .addSuccess(ClientSessionList)
      .addError(NotFound)
      .addError(QuotaExceeded)
      .addError(ServiceUnavailable)
      .annotateContext(
        OpenApi.annotations({
          summary: "List a VM's live client sessions",
          description:
            "List the live (not revoked) client sessions of this VM, oldest first: id, Linux user and creation time. Tokens are never returned; " +
            "they are shown once when the session is created. Requires the vm:exec scope. Another tenant's or another agent's VM is 404.",
        }),
      ),
  )
  .add(
    HttpApiEndpoint.del("revokeClientSession", "/v1/vms/:vmId/client-sessions/:sessionId")
      .setPath(SessionPath)
      .setHeaders(GroupTeamHeaders)
      .addSuccess(HttpApiSchema.NoContent)
      .addError(NotFound)
      .addError(QuotaExceeded)
      .addError(ServiceUnavailable)
      .annotateContext(
        OpenApi.annotations({
          summary: "Revoke a VM's client session",
          description: "Revoke a client session's provider token at once. Requires the vm:exec scope. Revoking twice is not an error.",
        }),
      ),
  ) {}
