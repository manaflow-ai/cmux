import { Effect, Schema } from "effect";
import { UpstreamError, UpstreamVm, type UpstreamClientService } from "./client.ts";
import { proofSegment, type UpstreamHttp } from "./live-http.ts";

const confirmed = (vm: UpstreamVm): boolean => vm.maxRunTotalSeconds === 0 && (vm.state === "paused" || vm.state === "stopped");

/** Provider-enforced budget: API callers and inbound traffic share the same fence. */
export const makeRetireVm = (http: UpstreamHttp): Pick<UpstreamClientService, "retireVm"> => ({
  retireVm: (_vm, { owns }) => Effect.gen(function* () {
    const path = `/v5/vms/${proofSegment(owns)}`;
    const fail = () => new UpstreamError({ operation: "retireVm", status: null });
    const read = () => http.json("retireVm", "GET", path).pipe(
      Effect.flatMap(Schema.decodeUnknown(UpstreamVm)), Effect.mapError((error) => error instanceof UpstreamError ? error : fail()),
    );
    const current = yield* read();
    if (confirmed(current)) return current;
    if (current.state === "running" && current.maxRunTotalSeconds !== 0) {
      // A flush failure must not keep a retired VM runnable. The command never wakes a paused VM.
      yield* http.json("retireVm", "POST", `${path}/exec-await`, { command: "sync", timeoutMs: 15_000, linuxUser: "root" }, { timeoutMs: 20_000 }).pipe(Effect.ignore);
    }
    // Zero covers even a freshly created VM that has used less than one second of compute.
    if (current.maxRunTotalSeconds !== 0) {
      yield* http.json("retireVm", "PATCH", path, { maxRunTotalSeconds: 0 }).pipe(Effect.ignore);
    }
    let after = yield* read();
    if (after.maxRunTotalSeconds !== 0) return yield* Effect.fail(fail());
    if (!confirmed(after)) {
      yield* http.json("retireVm", "POST", `${path}/pause`).pipe(Effect.ignore);
      after = yield* read();
    }
    return confirmed(after) ? after : yield* Effect.fail(fail());
  }),
});
