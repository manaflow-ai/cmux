import { mock } from "bun:test";

export function createTestflightUser({
  eligible = true,
}: { eligible?: boolean } = {}) {
  return {
    id: "user-pro",
    isAnonymous: false,
    primaryEmail: "Pro@Example.com",
    displayName: "Pro User",
    clientReadOnlyMetadata: {},
    listProducts: mock(async () =>
      Object.assign(
        eligible
          ? [
              {
                id: "pro",
                quantity: 1,
                subscription: {
                  cancelAtPeriodEnd: false,
                  currentPeriodEnd: new Date("2026-12-01T00:00:00Z"),
                },
              },
            ]
          : [],
        { nextCursor: null },
      ),
    ),
    update: mock(async () => undefined),
  };
}
