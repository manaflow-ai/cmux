import { mock } from "bun:test";

const testflightEligibilityKey = Symbol.for("cmux.tests.testflightEligibility");

export function createTestflightUser({
  eligible = true,
}: { eligible?: boolean } = {}) {
  const user = {
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
                  currentPeriodEnd: null,
                },
              },
            ]
          : [],
        { nextCursor: null },
      ),
    ),
    update: mock(async () => undefined),
  };
  Object.defineProperty(user, testflightEligibilityKey, {
    value: eligible,
    enumerable: false,
  });
  return user;
}

export function testflightUserEligibility(user: unknown): boolean | undefined {
  if (!user || typeof user !== "object") return undefined;
  const value = (user as Record<symbol, unknown>)[testflightEligibilityKey];
  return typeof value === "boolean" ? value : undefined;
}
