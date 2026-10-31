/**
 * Updating an owned VM's limits and an owned snapshot's retention (cx-b4h.2,
 * cx-b4h.9). The provider PATCH bodies are built from an allowlist: the name,
 * slug and metadata that carry tenant tagging, and the lifetime run budget that
 * keeps a retired VM retired, are never sent from here.
 */
import { Effect, Schema } from "effect";
import { UpstreamError, UpstreamVm, type UpstreamParityService } from "./client.ts";
import { proofSegment, type UpstreamHttp } from "./live-http.ts";
import { UpstreamSnapshot } from "./snapshots.ts";

const decodeAs =
  <A, I>(schema: Schema.Schema<A, I>, operation: string) =>
  (body: unknown): Effect.Effect<A, UpstreamError> =>
    Schema.decodeUnknown(schema)(body).pipe(Effect.mapError(() => new UpstreamError({ operation, status: null })));

export const makeUpdates = (http: UpstreamHttp): Pick<UpstreamParityService, "updateVm" | "updateSnapshot"> => ({
  updateVm: (_vm, { owns }, patch) => {
    const body: Record<string, number> = {};
    if (patch.idleTimeoutSeconds !== undefined) body["idleTimeoutSeconds"] = patch.idleTimeoutSeconds;
    if (patch.maxRunSeconds !== undefined) body["maxRunSeconds"] = patch.maxRunSeconds;
    if (patch.autoDeleteSeconds !== undefined) body["autoDeleteSeconds"] = patch.autoDeleteSeconds;
    const path = `/v5/vms/${proofSegment(owns)}`;
    const send = Object.keys(body).length === 0 ? http.json("updateVm", "GET", path) : http.json("updateVm", "PATCH", path, body);
    return send.pipe(Effect.flatMap(decodeAs(UpstreamVm, "updateVm")));
  },
  updateSnapshot: (_snapshot, { owns }, patch) => {
    const body: Record<string, number> = {};
    if (patch.ttlSeconds !== undefined) body["ttlSeconds"] = patch.ttlSeconds ?? -1;
    if (patch.autoDeleteSeconds !== undefined) body["autoDeleteSeconds"] = patch.autoDeleteSeconds ?? -1;
    const path = `/v5/snapshots/${proofSegment(owns)}`;
    const send = Object.keys(body).length === 0 ? http.json("updateSnapshot", "GET", path) : http.json("updateSnapshot", "PATCH", path, body);
    return send.pipe(Effect.flatMap(decodeAs(UpstreamSnapshot, "updateSnapshot")));
  },
});
