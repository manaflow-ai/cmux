/**
 * Client session identities on the tenant API (cx-b4h.6): the parity of the
 * provider's identity, VM permission and access token operations, served for
 * sessions cmux minted on the caller's own VMs only.
 *
 * A client session (src/api/agents.ts) is one provider identity with one grant
 * (this VM, exactly one Linux user) and its access tokens. Here a caller can
 * list its sessions across the team, read one, change its Linux user, and
 * list, mint and revoke its tokens. Tokens are shown once, when minted; token
 * ids are cmux ids, never the provider's. A session never gets an unrestricted
 * grant: its Linux user is always exactly one named user.
 */
import { HttpApiEndpoint, HttpApiGroup, HttpApiSchema, OpenApi } from "@effect/platform";
import { Schema } from "effect";
import { BadRequest, Conflict, Forbidden, NotFound, QuotaExceeded, ServiceUnavailable } from "../errors.ts";
import { ClientSessionId, ClientSessionTokenId } from "../lib/ids.ts";
import { ClientSessionSummary } from "./agents.ts";
import { GroupTeamHeaders } from "./common.ts";

export const LinuxUser = Schema.String.pipe(Schema.pattern(/^[a-z_][a-z0-9_-]{0,31}$/u)).annotations({
  description: "A Linux user name on the VM (lowercase letter or _ first, then lowercase letters, digits, _ or -; at most 32).",
});

export const ListClientSessionsParams = Schema.Struct({
  limit: Schema.optional(Schema.NumberFromString.pipe(Schema.int(), Schema.between(1, 200))),
  cursor: Schema.optional(ClientSessionId.annotations({ description: "The `nextCursor` of the previous page." })),
});

export class ClientSessionPage extends Schema.Class<ClientSessionPage>("ClientSessionPage")({
  /** Live sessions on the caller's live VMs, by session id. Never tokens. */
  sessions: Schema.Array(ClientSessionSummary),
  nextCursor: Schema.NullOr(Schema.String).annotations({ description: "Pass as `cursor` to read the next page; null on the last page." }),
}) {}

export class SetClientSessionLinuxUserRequest extends Schema.Class<SetClientSessionLinuxUserRequest>("SetClientSessionLinuxUserRequest")({
  /** The one Linux user the session's tokens may act as from now on. Required: a session is never unrestricted. */
  linuxUser: LinuxUser,
}) {}

export class ClientSessionTokenSummary extends Schema.Class<ClientSessionTokenSummary>("ClientSessionTokenSummary")({
  id: ClientSessionTokenId,
  sessionId: ClientSessionId,
}) {}

export class ClientSessionTokenList extends Schema.Class<ClientSessionTokenList>("ClientSessionTokenList")({
  /** The session's live tokens: ids only, never the token. */
  tokens: Schema.Array(ClientSessionTokenSummary),
}) {}

export class ClientSessionToken extends Schema.Class<ClientSessionToken>("ClientSessionToken")({
  id: ClientSessionTokenId,
  sessionId: ClientSessionId,
  vmId: Schema.String,
  /** The provider access token. Shown only in this response. Valid until revoked, the session is revoked or the VM is deleted. */
  token: Schema.String,
  /** The provider's id of this VM; the token is used with it directly. */
  providerVmId: Schema.String,
  linuxUser: Schema.String,
  /** Provider API origin for SDK clients. */
  apiBaseUrl: Schema.String,
  /** Provider SSH proxy: `ssh <user>@<host>` with the token as the password. */
  ssh: Schema.Struct({ host: Schema.String, user: Schema.String }),
  createdAt: Schema.String,
}) {}

const SessionPath = Schema.Struct({ vmId: Schema.String, sessionId: Schema.String });
const TokenPath = Schema.Struct({ vmId: Schema.String, sessionId: Schema.String, tokenId: Schema.String });

const describe = (summary: string, description: string) =>
  OpenApi.annotations({ summary, description: `${description} Requires the vm:exec scope.` });

/** Endpoints without the Authentication middleware; src/api.ts applies it. */
export class ClientSessionsGroupDefinition extends HttpApiGroup.make("clientSessions")
  .add(
    HttpApiEndpoint.get("listTenantClientSessions", "/v1/client-sessions")
      .setUrlParams(ListClientSessionsParams)
      .setHeaders(GroupTeamHeaders)
      .addSuccess(ClientSessionPage)
      .addError(BadRequest)
      .addError(Forbidden)
      .addError(QuotaExceeded)
      .addError(ServiceUnavailable)
      .annotateContext(
        describe(
          "List the team's live client sessions",
          "List the live client sessions on the caller's live VMs, across the team, by session id (default limit 100, at most 200). " +
            "Only sessions on VMs the credential reaches are listed: a key limited to resources or labels sees only those VMs' sessions. " +
            "Tokens are never returned. A filtered page can hold fewer than `limit` items; follow `nextCursor`.",
        ),
      ),
  )
  .add(
    HttpApiEndpoint.get("getClientSession", "/v1/vms/:vmId/client-sessions/:sessionId")
      .setPath(SessionPath)
      .setHeaders(GroupTeamHeaders)
      .addSuccess(ClientSessionSummary)
      .addError(NotFound)
      .addError(QuotaExceeded)
      .addError(ServiceUnavailable)
      .annotateContext(
        describe(
          "Read a VM's client session",
          "Read one live client session of this VM: id, its one Linux user and creation time. A revoked session, another VM's session, " +
            "or another tenant's or agent's VM is 404.",
        ),
      ),
  )
  .add(
    HttpApiEndpoint.put("setClientSessionLinuxUser", "/v1/vms/:vmId/client-sessions/:sessionId/linux-user")
      .setPath(SessionPath)
      .setPayload(SetClientSessionLinuxUserRequest)
      .setHeaders(GroupTeamHeaders)
      .addSuccess(ClientSessionSummary)
      .addError(BadRequest)
      .addError(NotFound)
      .addError(Conflict)
      .addError(QuotaExceeded)
      .addError(ServiceUnavailable)
      .annotateContext(
        describe(
          "Change a client session's Linux user",
          "Replace the one Linux user the session's tokens (existing and future) may act as on this VM. Exactly one user: a session is never " +
            "unrestricted. Setting the current user again is not an error. A revoked session is 404. A change that raced another change " +
            "of the same session and lost is 409; the session keeps the winner's user, on the grant too.",
        ),
      ),
  )
  .add(
    HttpApiEndpoint.get("listClientSessionTokens", "/v1/vms/:vmId/client-sessions/:sessionId/tokens")
      .setPath(SessionPath)
      .setHeaders(GroupTeamHeaders)
      .addSuccess(ClientSessionTokenList)
      .addError(NotFound)
      .addError(QuotaExceeded)
      .addError(ServiceUnavailable)
      .annotateContext(
        describe(
          "List a client session's tokens",
          "List the live access tokens of a live client session: their ids only. Tokens are shown once, when minted. A revoked session is 404.",
        ),
      ),
  )
  .add(
    HttpApiEndpoint.post("createClientSessionToken", "/v1/vms/:vmId/client-sessions/:sessionId/tokens")
      .setPath(SessionPath)
      .setHeaders(GroupTeamHeaders)
      .addSuccess(ClientSessionToken, { status: 201 })
      .addError(NotFound)
      .addError(QuotaExceeded)
      .addError(ServiceUnavailable)
      .annotateContext(
        describe(
          "Mint another token for a client session",
          "Mint another access token for a live client session: same VM, same Linux user. The token is shown once; the response carries the SSH " +
            "login and API origin like the session's first token. A revoked session is 404.",
        ),
      ),
  )
  .add(
    HttpApiEndpoint.del("revokeClientSessionToken", "/v1/vms/:vmId/client-sessions/:sessionId/tokens/:tokenId")
      .setPath(TokenPath)
      .setHeaders(GroupTeamHeaders)
      .addSuccess(HttpApiSchema.NoContent)
      .addError(NotFound)
      .addError(QuotaExceeded)
      .addError(ServiceUnavailable)
      .annotateContext(
        describe(
          "Revoke one token of a client session",
          "Revoke one access token at once; the session and its other tokens stay. Revoking a token that is already gone is not an error. " +
            "A revoked session, or a token id that is malformed, is 404.",
        ),
      ),
  ) {}
