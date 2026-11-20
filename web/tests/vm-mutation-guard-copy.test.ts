import { describe, expect, test } from "bun:test";
import { locales } from "../i18n/routing";
import { vmMutationGuardCopy } from "../services/vms/vmErrorMessages";

describe("Cloud VM mutation guard copy", () => {
  test("every web locale has allocation and snapshot idempotency guidance", async () => {
    for (const locale of locales) {
      for (const key of [
        "allocationUnavailable",
        "snapshotIdempotencyRequired",
        "snapshotInProgress",
        "snapshotIdempotencyConflict",
        "snapshotQuota",
      ] as const) {
        const copy = await vmMutationGuardCopy(
          key as Parameters<typeof vmMutationGuardCopy>[0],
          locale,
        );
        expect(copy.title.length).toBeGreaterThan(0);
        expect(copy.message.length).toBeGreaterThan(0);
        expect(copy.action.length).toBeGreaterThan(0);
        expect(JSON.stringify(copy)).not.toContain(`vmErrors.${key}`);
      }
    }
  });

  test("serves Japanese snapshot-idempotency guidance", async () => {
    expect(await vmMutationGuardCopy("snapshotIdempotencyRequired", "ja")).toEqual({
      title: "スナップショットリクエストには再試行キーが必要です",
      message: "Cloud VM のスナップショットには冪等キーが必要です。",
      action: "128 文字以内の固定した Idempotency-Key を指定して再試行してください。",
    });
  });
});
