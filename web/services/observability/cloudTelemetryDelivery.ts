import { Effect } from "effect";
import { cloudAxiomConfiguration, exportCloudDiagnostics } from "./cloudTelemetryExport";
import { claimCloudDiagnostics, expireCloudDiagnostics, finishCloudDiagnostics } from "./cloudTelemetryRepository";

/** Bounded drain used after ingress and by cron, with leases shared across instances. */
export function drainCloudDiagnostics() {
  return Effect.runPromise(Effect.gen(function* () {
    const configuration = cloudAxiomConfiguration();
    if (!configuration) return { configured: false, delivered: 0 };
    const { leaseId, rows } = yield* Effect.tryPromise(() => claimCloudDiagnostics());
    if (!rows.length) return { configured: true, delivered: 0 };
    const exported = yield* Effect.tryPromise(() => exportCloudDiagnostics(rows, configuration)).pipe(
      Effect.match({ onFailure: () => false, onSuccess: () => true }),
    );
    yield* Effect.tryPromise(() => finishCloudDiagnostics(leaseId, exported));
    if (!exported) console.error("cmux.cloud.diagnostics.export_failed", { count: rows.length });
    return { configured: true, delivered: exported ? rows.length : 0 };
  }));
}

export async function maintainCloudDiagnostics() {
  const delivery = await drainCloudDiagnostics();
  const retention = await expireCloudDiagnostics();
  if (retention.expiredUndelivered > 0) console.error("cmux.cloud.diagnostics.expired_undelivered", retention);
  return { ...delivery, ...retention };
}
