import { HttpApiEndpoint, HttpApiGroup, HttpApiSchema, OpenApi } from "@effect/platform";
import { Schema } from "effect";
import { AccessTokenId, AccessTokenScope, ACCESS_TOKEN_SCOPES } from "./tokens.ts";
import { VmId, UserId } from "../lib/ids.ts";
import { BadRequest, Forbidden, NotFound, QuotaExceeded, ServiceUnavailable } from "../errors.ts";
import { GroupTeamHeaders } from "../api/common.ts";

const PrincipalId = UserId.annotations({ description: "The tenant's own end-user or agent id." });
const LinuxUser = Schema.String.pipe(Schema.pattern(/^[a-z_][a-z0-9_-]{0,63}$/u));
const AccessScopes = Schema.Array(AccessTokenScope).pipe(Schema.minItems(1), Schema.maxItems(ACCESS_TOKEN_SCOPES.length));
const VmIds = Schema.Array(VmId).pipe(Schema.minItems(1), Schema.maxItems(50));

export class CreateAccessTokenRequest extends Schema.Class<CreateAccessTokenRequest>("CreateAccessTokenRequest")({
  principal: PrincipalId,
  vmIds: VmIds,
  scopes: AccessScopes,
  ttlSeconds: Schema.optional(Schema.Int.pipe(Schema.between(1, 86400))),
  linuxUser: Schema.optional(LinuxUser),
}) {}

export class AccessToken extends Schema.Class<AccessToken>("AccessToken")({
  id: AccessTokenId,
  principal: UserId,
  vmIds: VmIds,
  scopes: AccessScopes,
  linuxUser: Schema.String,
  createdBy: Schema.String,
  createdAt: Schema.String,
  expiresAt: Schema.String,
  revokedAt: Schema.NullOr(Schema.String),
}) {}

export class CreatedAccessToken extends Schema.Class<CreatedAccessToken>("CreatedAccessToken")({
  id: AccessTokenId,
  token: Schema.String,
  expiresAt: Schema.String,
}) {}

export class AccessTokenList extends Schema.Class<AccessTokenList>("AccessTokenList")({ items: Schema.Array(AccessToken) }) {}

export class SshAccess extends Schema.Class<SshAccess>("SshAccess")({
  host: Schema.String,
  user: Schema.String,
  password: Schema.String,
}) {}

const TokenPath = Schema.Struct({ tokenId: Schema.String });
const describe = (summary: string) => OpenApi.annotations({ summary, description: `${summary}. Requires the access-token:create scope or a signed-in team session.` });

export class AccessTokensGroupDefinition extends HttpApiGroup.make("accessTokens")
  .add(
    HttpApiEndpoint.post("createAccessToken", "/v1/access-tokens")
      .setPayload(CreateAccessTokenRequest)
      .setHeaders(GroupTeamHeaders)
      .addSuccess(CreatedAccessToken, { status: 201 })
      .addError(BadRequest)
      .addError(Forbidden)
      .addError(NotFound)
      .addError(QuotaExceeded)
      .addError(ServiceUnavailable)
      .annotateContext(describe("Mint an end-user access token")),
  )
  .add(
    HttpApiEndpoint.get("listAccessTokens", "/v1/access-tokens")
      .setHeaders(GroupTeamHeaders)
      .addSuccess(AccessTokenList)
      .addError(Forbidden)
      .addError(QuotaExceeded)
      .addError(ServiceUnavailable)
      .annotateContext(describe("List access tokens without their secrets")),
  )
  .add(
    HttpApiEndpoint.del("revokeAccessToken", "/v1/access-tokens/:tokenId")
      .setPath(TokenPath)
      .setHeaders(GroupTeamHeaders)
      .addSuccess(HttpApiSchema.NoContent)
      .addError(Forbidden)
      .addError(NotFound)
      .addError(ServiceUnavailable)
      .annotateContext(describe("Revoke an access token")),
  )
  .add(
    HttpApiEndpoint.post("mintAccessTokenSsh", "/v1/access-tokens/:tokenId/ssh")
      .setPath(TokenPath)
      .setHeaders(GroupTeamHeaders)
      .addSuccess(SshAccess)
      .addError(Forbidden)
      .addError(NotFound)
      .addError(ServiceUnavailable)
      .annotateContext(describe("Mint a delegated SSH credential")),
  ) {}
