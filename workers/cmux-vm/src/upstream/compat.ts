import { Context, Data, Effect, Layer, Redacted } from "effect";
import { type Named } from "@gdp-ts/core";
import type { Principal } from "../domain/principal.ts";
import type { ResourceId } from "../lib/ids.ts";
import type { TenantMayCreate } from "../proofs/tenant-may-create.ts";
import type { KeyHasScope } from "../proofs/key-has-scope.ts";
import { upstreamIdOf, type TenantOwnsResource } from "../proofs/tenant-owns-resource.ts";
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
  readonly forwardOwned: <C, R extends ResourceId>(proof: TenantOwnsResource<C, R>, input: CompatRequest) => Effect.Effect<Response, CompatUpstreamError>;
  readonly forwardCreate: <C, K extends "vm" | "snapshot">(
    caller: Named<C, Principal>,
    proof: TenantMayCreate<C, K>,
    input: CompatRequest,
  ) => Effect.Effect<Response, CompatUpstreamError>;
  readonly forwardAuthorized: <C>(caller: Named<C, Principal>, proof: KeyHasScope<C, "vm:write">, input: CompatRequest) => Effect.Effect<Response, CompatUpstreamError>;
}

export class CompatUpstream extends Context.Tag("cmux-vm/CompatUpstream")<CompatUpstream, CompatUpstreamService>() {}

const pathFor = (template: string, upstreamId: string): string => {
  if (!template.includes("{id}")) throw new Error("compat route template must contain {id}");
  return template.replace("{id}", encodeURIComponent(upstreamId));
};

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
    forwardOwned: (proof, input) => forward({ ...input, template: pathFor(input.template, upstreamIdOf(proof)) }, input.identityAccessToken === undefined ? providerAuth : `Bearer ${input.identityAccessToken}`),
    forwardCreate: (_caller, _proof, input) => forward(input, providerAuth),
    forwardAuthorized: (_caller, _proof, input) => forward(input, providerAuth),
  };
};

export const compatUpstreamLayer = (config: { readonly baseUrl: string; readonly apiKey: string; readonly environment: UpstreamConfig["environment"]; readonly fetch?: (request: Request) => Promise<Response> }): Layer.Layer<CompatUpstream> =>
  Layer.succeed(CompatUpstream, makeCompatUpstream({ ...config, apiKey: Redacted.make(config.apiKey) }));
