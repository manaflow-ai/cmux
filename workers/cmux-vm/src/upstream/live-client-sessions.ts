/**
 * Per-VM client sessions: one provider identity, granted exactly one owned VM
 * and one Linux user, with one access token. The token is returned once for
 * the caller; the identity id stays server-side so the session can be revoked
 * (deleting an identity deletes its tokens and grants). The provider key never
 * leaves this module's transport.
 */
import { Effect, Schema } from "effect";
import { UpstreamId } from "../lib/ids.ts";
import { upstreamIdOf } from "../proofs/tenant-owns-resource.ts";
import { UpstreamError, type UpstreamClientService } from "./client.ts";
import type { UpstreamHttp } from "./live-http.ts";
import { publicTokenId } from "./live-client-session-tokens.ts";

const CreatedIdentity = Schema.Struct({ id: Schema.String.pipe(Schema.minLength(1), Schema.maxLength(200)) });
const CreatedToken = Schema.Struct({ id: Schema.String, token: Schema.String.pipe(Schema.minLength(1)) });

/** The provider's SSH proxy (docs: freestyle.sh/docs/vms/ssh); the token is the password, `<vm>+<user>` the login. */
export const PROVIDER_SSH_HOST = "beta-ssh.freestyle.sh";

export const makeClientSessions = (
  http: UpstreamHttp,
  apiBaseUrl: string,
): Pick<UpstreamClientService, "openClientSession" | "deleteIdentity"> => {
  const deleteIdentity: UpstreamClientService["deleteIdentity"] = (identityId) =>
    http.json("deleteIdentity", "DELETE", `/v5/identities/${encodeURIComponent(identityId)}`).pipe(
      Effect.as("deleted" as const),
      Effect.catchAll((error) => (error.status === 404 ? Effect.succeed("gone" as const) : Effect.fail(error))),
    );
  return {
    deleteIdentity,
    openClientSession: (_vm, { owns }, linuxUser) =>
      Effect.gen(function* () {
        const providerVmId = upstreamIdOf(owns);
        const malformed = (operation: string) => () => new UpstreamError({ operation, status: null });
        const identity = yield* http.json("createIdentity", "POST", "/v5/identities", {}).pipe(
          Effect.flatMap((body) => Schema.decodeUnknown(CreatedIdentity)(body).pipe(Effect.mapError(malformed("createIdentity")))),
        );
        const identityId = UpstreamId.make(identity.id);
        const base = `/v5/identities/${encodeURIComponent(identityId)}`;
        const granted = yield* Effect.gen(function* () {
          yield* http.json("grantVmPermission", "POST", `${base}/permissions/vm`, { vmId: providerVmId, allowedLinuxUsers: [linuxUser] });
          return yield* http.json("createAccessToken", "POST", `${base}/tokens`).pipe(
            Effect.flatMap((body) => Schema.decodeUnknown(CreatedToken)(body).pipe(Effect.mapError(malformed("createAccessToken")))),
          );
        }).pipe(
          // Nothing half-made survives: an identity without its grant or token is deleted again.
          Effect.tapError(() => deleteIdentity(identityId).pipe(Effect.ignore)),
        );
        return {
          upstreamIdentityId: identityId,
          token: granted.token,
          tokenId: yield* publicTokenId(identityId, granted.id),
          providerVmId,
          apiBaseUrl,
          sshHost: PROVIDER_SSH_HOST,
        };
      }),
  };
};
