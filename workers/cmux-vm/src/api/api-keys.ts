/**
 * API keys (cx-b4h.12): create, list and revoke the caller's tenant's cmux VM
 * API keys. Needs the `admin` scope, or a session of a team admin. A new key
 * never exceeds its issuer: its scopes are a subset of the issuer's, and an
 * issuer limited to a resource allowlist can only issue keys inside it. The
 * full key is returned once, by create; only its SHA-256 hash is stored.
 */
import { HttpApiEndpoint, HttpApiGroup, HttpApiSchema, OpenApi } from "@effect/platform";
import { Schema } from "effect";
import { Scope } from "../domain/scopes.ts";
import { NotFound, QuotaExceeded } from "../errors.ts";
import { ApiKeyId, SnapshotId, VmId } from "../lib/ids.ts";
import { GroupTeamHeaders, InvalidRequest } from "./common.ts";

const MAX_ALLOWLIST = 100;

const ApiKeyName = Schema.String.pipe(Schema.minLength(1), Schema.maxLength(200));
const ResourceAllowlist = Schema.Array(Schema.Union(VmId, SnapshotId)).pipe(Schema.minItems(1), Schema.maxItems(MAX_ALLOWLIST));

export class ApiKey extends Schema.Class<ApiKey>("ApiKey")({
  id: ApiKeyId,
  name: Schema.String,
  scopes: Schema.Array(Scope),
  /** When set, the key reaches only these resources; null means every resource of the team. */
  resourceAllowlist: Schema.NullOr(Schema.Array(Schema.String)),
  /** `user:<id>` or `key:<id>` of the issuer. */
  createdBy: Schema.String,
  createdAt: Schema.String,
  expiresAt: Schema.NullOr(Schema.String),
  revokedAt: Schema.NullOr(Schema.String),
}) {}

export class CreatedApiKey extends Schema.Class<CreatedApiKey>("CreatedApiKey")({
  id: ApiKeyId,
  name: Schema.String,
  scopes: Schema.Array(Scope),
  resourceAllowlist: Schema.NullOr(Schema.Array(Schema.String)),
  createdAt: Schema.String,
  expiresAt: Schema.NullOr(Schema.String),
  /** The full key. Shown only in this response; store it now. */
  key: Schema.String,
}) {}

export class ApiKeyList extends Schema.Class<ApiKeyList>("ApiKeyList")({ items: Schema.Array(ApiKey) }) {}

export class CreateApiKeyRequest extends Schema.Class<CreateApiKeyRequest>("CreateApiKeyRequest")({
  name: ApiKeyName,
  scopes: Schema.Array(Scope).pipe(Schema.minItems(1), Schema.maxItems(32)),
  /** Limit the key to these VM and snapshot ids. Omit for every resource the issuer can reach. */
  resourceAllowlist: Schema.optional(ResourceAllowlist),
  /** When the key stops working. Omit for no expiry. */
  expiresAt: Schema.optional(Schema.DateFromString),
}) {}

const KeyPath = Schema.Struct({ keyId: Schema.String });

const describeAdmin = (summary: string) =>
  OpenApi.annotations({ summary, description: `${summary}. Requires the admin scope, or a session of a team admin.` });

/** Endpoints without the Authentication middleware; src/api.ts applies it. */
export class ApiKeysGroupDefinition extends HttpApiGroup.make("apiKeys")
  .add(
    HttpApiEndpoint.post("createApiKey", "/v1/api-keys")
      .setPayload(CreateApiKeyRequest)
      .setHeaders(GroupTeamHeaders)
      .addSuccess(CreatedApiKey, { status: 201 })
      .addError(InvalidRequest)
      .addError(QuotaExceeded)
      .annotateContext(describeAdmin("Create an API key for the team; the full key is returned only here")),
  )
  .add(
    HttpApiEndpoint.get("listApiKeys", "/v1/api-keys")
      .setHeaders(GroupTeamHeaders)
      .addSuccess(ApiKeyList)
      .addError(QuotaExceeded)
      .annotateContext(describeAdmin("List the team's API keys, newest first, without their secrets")),
  )
  .add(
    HttpApiEndpoint.del("revokeApiKey", "/v1/api-keys/:keyId")
      .setPath(KeyPath)
      .setHeaders(GroupTeamHeaders)
      .addSuccess(HttpApiSchema.NoContent)
      .addError(NotFound)
      .addError(QuotaExceeded)
      .annotateContext(describeAdmin("Revoke an API key; it stops working at once")),
  ) {}
