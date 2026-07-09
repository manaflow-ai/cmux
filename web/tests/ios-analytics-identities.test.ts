import { describe, expect, test } from "bun:test";
import {
  recordIOSAnalyticsIdentities,
  type IOSAnalyticsIdentityRuntime,
} from "../services/analytics/iosAnalyticsIdentities";

describe("iOS analytics identities", () => {
  test("caps per-request identity writes without evicting deletion aliases", async () => {
    const inserted: Array<{ readonly anonymousId: string }> = [];
    const runtime = {
      cloudDb: () => ({
        transaction: async (fn: (tx: unknown) => Promise<void>) => {
          await fn({
            insert: () => ({
              values: (values: Array<{ readonly anonymousId: string }>) => {
                inserted.push(...values);
                return {
                  onConflictDoUpdate: async () => {},
                };
              },
            }),
          });
        },
      }),
    } as unknown as IOSAnalyticsIdentityRuntime;

    await recordIOSAnalyticsIdentities({
      userId: "stack-user-1",
      anonymousIds: [
        "stack-user-1",
        ...Array.from({ length: 25 }, (_, index) => `00000000-0000-4000-8000-${String(index).padStart(12, "0")}`),
      ],
    }, runtime);

    expect(inserted.map((row) => row.anonymousId)).toEqual(
      Array.from({ length: 16 }, (_, index) => `00000000-0000-4000-8000-${String(index).padStart(12, "0")}`),
    );
  });
});
