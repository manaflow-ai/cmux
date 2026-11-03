/** Stable provider identity, exact recovery and one potentially allocating send per mesh intent. */
import { Effect, Option, Redacted, Schema } from "effect";
import type { Named } from "@gdp-ts/core";
import { UpstreamId, type MeshId } from "../lib/ids.ts";
import { sha256Hex } from "../mesh/signed-request.ts";
import { pendingMeshCreationEvidenceOf, type PendingMeshCreation } from "../proofs/mesh-creation.ts";
import { UpstreamError } from "./client.ts";
import { makeUpstreamHttp } from "./live-http.ts";
import type { UpstreamConfig } from "./live.ts";
import type { CreatedNetwork, UpstreamMeshService } from "./mesh.ts";
import { upstreamName } from "./naming.ts";

const Receipt = Schema.Struct({ id: UpstreamId, slug: Schema.String, cidr: Schema.String, displayName: Schema.String });

export const makeDurableMeshCreate = (config: UpstreamConfig, track: (created: CreatedNetwork) => void): Pick<UpstreamMeshService, "recoverNetwork" | "createJournalledNetwork"> => {
  const http = makeUpstreamHttp(config);
  const prepare = <C, M>(mesh: Named<M, MeshId>, pending: PendingMeshCreation<C, M>) => Effect.gen(function* () {
    const held = pendingMeshCreationEvidenceOf(pending);
    const body = { slug: `cmux-mesh-${config.environment}-${mesh.value.replace("_", "-")}`, displayName: upstreamName(config.environment, held.tenantId, mesh.value), cidr: held.cidr };
    const context = yield* sha256Hex(JSON.stringify([config.baseUrl, Redacted.value(config.apiKey), body]));
    yield* held.context(context);
    yield* held.active;
    return { held, body };
  });
  const checked = (body: unknown, expected: { slug: string; cidr: string; displayName: string }) =>
    Schema.decodeUnknown(Receipt)(body).pipe(
      Effect.mapError(() => new UpstreamError({ operation: "meshCreationReceipt", status: null })),
      Effect.flatMap((receipt) => {
        if (receipt.slug !== expected.slug || receipt.cidr !== expected.cidr || receipt.displayName !== expected.displayName)
          return Effect.fail(new UpstreamError({ operation: "meshCreationReceipt", status: null }));
        const created: CreatedNetwork = Object.freeze({ upstreamId: receipt.id, cidr: receipt.cidr });
        track(created);
        return Effect.succeed(created);
      }),
    );
  const recover = (body: { slug: string; cidr: string; displayName: string }) =>
    http.json("recoverCreateNetwork", "GET", `/v5/vpcs/${encodeURIComponent(body.slug)}`).pipe(
      Effect.flatMap((answer) => checked(answer, body)), Effect.map(Option.some),
      Effect.catchAll((error) => error.status === 404 ? Effect.succeed(Option.none<CreatedNetwork>()) : Effect.fail(error)),
    );
  return {
    recoverNetwork: (mesh, { pending }) => prepare(mesh, pending).pipe(Effect.flatMap(({ body }) => recover(body))),
    createJournalledNetwork: (mesh, { pending }) => Effect.gen(function* () {
      const { held, body } = yield* prepare(mesh, pending);
      const existing = yield* recover(body);
      if (Option.isSome(existing)) return existing.value;
      const token = yield* held.beginSend();
      return yield* http.json("createNetwork", "POST", "/v5/vpcs", body).pipe(
        Effect.tapError((error) => error.status === 400 || error.status === 409 || error.status === 429 ? held.rejected(token) : Effect.void),
        Effect.flatMap((answer) => checked(answer, body)),
        Effect.catchAll((error) => recover(body).pipe(Effect.flatMap((found) => Option.isSome(found) ? Effect.succeed(found.value) : Effect.fail(error)))),
      );
    }),
  };
};
