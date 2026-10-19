import { Context, Data, Effect, Layer, Redacted } from "effect";
import { type Named } from "@gdp-ts/core";
import type { Principal } from "../domain/principal.ts";
import type { IdentityId, SnapshotId, VmId } from "../lib/ids.ts";
import type { TenantMayCreate } from "../proofs/tenant-may-create.ts";
import type { KeyHasScope } from "../proofs/key-has-scope.ts";
import type { Scope } from "../domain/scopes.ts";
import type { CompatCreatedResource } from "../proofs/compat-created-resource.ts";
import { upstreamIdOf, type TenantOwnsResource } from "../proofs/tenant-owns-resource.ts";
import { upstreamIdOfCreated } from "../proofs/compat-created-resource.ts";
import type { UpstreamConfig } from "./live.ts";

export class CompatUpstreamError extends Data.TaggedError("CompatUpstreamError")<{
  readonly operation: string;
  readonly status: number | null;
}> {}

export interface CompatRequest {
  readonly request: Request;
  readonly template: string;
  readonly operation: string;
  readonly identityAccessToken?: string;
}

export interface CompatUpstreamService {
  readonly forwardVm: <C, R>(proof: TenantOwnsResource<C, R, "vm">, input: CompatRequest) => Effect.Effect<Response, CompatUpstreamError>;
  readonly forwardSnapshot: <C, R>(proof: TenantOwnsResource<C, R, "snapshot">, input: CompatRequest) => Effect.Effect<Response, CompatUpstreamError>;
  readonly forwardIdentity: <C, R>(proof: TenantOwnsResource<C, R, "identity">, input: CompatRequest) => Effect.Effect<Response, CompatUpstreamError>;
  readonly forwardGrant: <C, I, V>(identityProof: TenantOwnsResource<C, I, "identity">, vmProof: TenantOwnsResource<C, V, "vm">, input: CompatRequest) => Effect.Effect<Response, CompatUpstreamError>;
  readonly forwardCreatedVm: <C>(caller: Named<C, Principal>, proof: CompatCreatedResource<C, "vm">, input: CompatRequest) => Effect.Effect<Response, CompatUpstreamError>;
  readonly discardCreatedVm: <C>(caller: Named<C, Principal>, proof: CompatCreatedResource<C, "vm">) => Effect.Effect<void, CompatUpstreamError>;
  readonly discardCreatedSnapshot: <C>(caller: Named<C, Principal>, proof: CompatCreatedResource<C, "snapshot">) => Effect.Effect<void, CompatUpstreamError>;
  readonly discardCreatedIdentity: <C>(caller: Named<C, Principal>, proof: CompatCreatedResource<C, "identity">) => Effect.Effect<void, CompatUpstreamError>;
  readonly forwardAuthorized: <C, S extends Scope>(caller: Named<C, Principal>, proof: KeyHasScope<C, S>, input: CompatRequest) => Effect.Effect<Response, CompatUpstreamError>;
  readonly forwardCreate: <C, K extends "vm" | "snapshot">(
    caller: Named<C, Principal>,
    proof: TenantMayCreate<C, K>,
    input: CompatRequest,
  ) => Effect.Effect<Response, CompatUpstreamError>;
}

export class CompatUpstream extends Context.Tag("cmux-vm/CompatUpstream")<CompatUpstream, CompatUpstreamService>() {}

const pathFor = (template: string, upstreamId: string): string => {
  if (!template.includes("{id}")) throw new Error("compat route template must contain {id}");
  return template.replace("{id}", encodeURIComponent(upstreamId));
};
const pathForGrant = (template: string, identityId: string, vmId: string): string => template.replace("{identity}", encodeURIComponent(identityId)).replace("{vm}", encodeURIComponent(vmId));

const copyHeaders = (request: Request, authorization: string): Headers => {
  const headers = new Headers();
  for (const key of ["content-type", "accept", "range", "content-range"]) {
    const value = request.headers.get(key);
    if (value !== null) headers.set(key, value);
  }
  const identity = request.headers.get("x-freestyle-identity-access-token");
  if (identity !== null) headers.set("x-freestyle-identity-access-token", identity);
  headers.set("authorization", authorization);
  headers.set("accept", request.headers.get("accept") ?? "application/json");
  return headers;
};

export const makeCompatUpstream = (config: UpstreamConfig): CompatUpstreamService => {
  const base = new URL(config.baseUrl);
  const send = config.fetch ?? ((request: Request) => fetch(request));
  const providerAuth = `Bearer ${Redacted.value(config.apiKey)}`;
  const forward = (input: CompatRequest, authorization: string): Effect.Effect<Response, CompatUpstreamError> =>
    Effect.tryPromise({
      try: async () => {
        const body = input.request.body === null ? undefined : await input.request.clone().arrayBuffer();
        const outgoing = new Request(new URL(input.template, base), {
          method: input.request.method,
          headers: copyHeaders(input.request, authorization),
          ...(body === undefined ? {} : { body }),
          redirect: "manual",
        });
        return await send(outgoing);
      },
      catch: () => new CompatUpstreamError({ operation: input.operation, status: null }),
    });
  return {
    forwardVm: (proof, input) => forward({ ...input, template: pathFor(input.template, upstreamIdOf(proof)) }, input.identityAccessToken === undefined ? providerAuth : `Bearer ${input.identityAccessToken}`),
    forwardSnapshot: (proof, input) => forward({ ...input, template: pathFor(input.template, upstreamIdOf(proof)) }, input.identityAccessToken === undefined ? providerAuth : `Bearer ${input.identityAccessToken}`),
    forwardIdentity: (proof, input) => forward({ ...input, template: pathFor(input.template, upstreamIdOf(proof)) }, input.identityAccessToken === undefined ? providerAuth : `Bearer ${input.identityAccessToken}`),
    forwardGrant: (identityProof, vmProof, input) => forward({ ...input, template: pathForGrant(input.template, upstreamIdOf(identityProof), upstreamIdOf(vmProof)) }, providerAuth),
    forwardCreatedVm: <C>(_caller: Named<C, Principal>, proof: CompatCreatedResource<C, "vm">, input: CompatRequest) => forward({ ...input, template: pathFor(input.template, upstreamIdOfCreated(proof)) }, providerAuth),
    discardCreatedVm: <C>(_caller: Named<C, Principal>, proof: CompatCreatedResource<C, "vm">) => forward({ request: new Request("https://compat.invalid", { method: "DELETE" }), template: `/v5/vms/${encodeURIComponent(upstreamIdOfCreated(proof))}`, operation: "discardCreatedVm" }, providerAuth).pipe(Effect.asVoid),
    discardCreatedSnapshot: <C>(_caller: Named<C, Principal>, proof: CompatCreatedResource<C, "snapshot">) => forward({ request: new Request("https://compat.invalid", { method: "DELETE" }), template: `/v5/snapshots/${encodeURIComponent(upstreamIdOfCreated(proof))}`, operation: "discardCreatedSnapshot" }, providerAuth).pipe(Effect.asVoid),
    discardCreatedIdentity: <C>(_caller: Named<C, Principal>, proof: CompatCreatedResource<C, "identity">) => forward({ request: new Request("https://compat.invalid", { method: "DELETE" }), template: `/v5/identities/${encodeURIComponent(upstreamIdOfCreated(proof))}`, operation: "discardCreatedIdentity" }, providerAuth).pipe(Effect.asVoid),
    forwardCreate: (_caller, _proof, input) => forward(input, providerAuth),
    forwardAuthorized: <C, S extends Scope>(_caller: Named<C, Principal>, _proof: KeyHasScope<C, S>, input: CompatRequest) => forward(input, providerAuth),
  };
};

export const compatUpstreamLayer = (config: { readonly baseUrl: string; readonly apiKey: string; readonly environment: UpstreamConfig["environment"]; readonly fetch?: (request: Request) => Promise<Response> }): Layer.Layer<CompatUpstream> =>
  Layer.succeed(CompatUpstream, makeCompatUpstream({ ...config, apiKey: Redacted.make(config.apiKey) }));
