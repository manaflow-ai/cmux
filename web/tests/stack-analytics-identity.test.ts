import { describe, expect, mock, test } from "bun:test";

import {
  STACK_IDENTITY_STORAGE_KEY,
  syncStackAnalyticsIdentity,
} from "../services/analytics/stackIdentity";

function harness(initialUserId?: string) {
  const values = new Map<string, string>();
  if (initialUserId) values.set(STACK_IDENTITY_STORAGE_KEY, initialUserId);
  return {
    identify: mock(() => {}),
    reset: mock(() => {}),
    storage: {
      getItem: (key: string) => values.get(key) ?? null,
      setItem: (key: string, value: string) => values.set(key, value),
      removeItem: (key: string) => values.delete(key),
    },
    values,
  };
}

describe("Stack PostHog identity bridge", () => {
  test("identifies signed-in Stack users without profile PII", () => {
    const h = harness();

    syncStackAnalyticsIdentity(h, h.storage, {
      id: "stack-user-1",
      plan: "pro",
    });

    expect(h.identify).toHaveBeenCalledWith("stack-user-1", {
      stack_user_id: "stack-user-1",
      authentication_provider: "stack",
      billing_plan: "pro",
      is_pro: true,
    });
    expect(h.reset).not.toHaveBeenCalled();
    expect(h.values.get(STACK_IDENTITY_STORAGE_KEY)).toBe("stack-user-1");
  });

  test("resets after logout but preserves ordinary anonymous funnels", () => {
    const anonymous = harness();
    syncStackAnalyticsIdentity(anonymous, anonymous.storage, null);
    expect(anonymous.reset).not.toHaveBeenCalled();

    const signedOut = harness("stack-user-1");
    syncStackAnalyticsIdentity(signedOut, signedOut.storage, null);
    expect(signedOut.reset).toHaveBeenCalledTimes(1);
    expect(signedOut.values.has(STACK_IDENTITY_STORAGE_KEY)).toBe(false);
  });
});
