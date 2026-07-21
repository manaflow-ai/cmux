import { describe, expect, test } from "bun:test";
import {
  MAX_ACTIVE_SHARES_PER_OWNER,
  MAX_SHARE_CREATIONS_PER_MINUTE,
  reserveOwnerShare,
  type OwnerIndexState,
} from "../src/shareOwnerState";

const empty: OwnerIndexState = { activeShares: [], creationTimes: [] };

describe("share owner quotas", () => {
  test("caps active rooms per authenticated owner", () => {
    let state = empty;
    for (let index = 0; index < MAX_ACTIVE_SHARES_PER_OWNER; index += 1) {
      const result = reserveOwnerShare(state, `share-${index}`, 100_000, 1_000 + index);
      expect(result.ok).toBe(true);
      state = result.state;
    }
    expect(reserveOwnerShare(state, "overflow", 100_000, 2_000)).toMatchObject({
      ok: false,
      error: "too_many_active_shares",
    });
  });

  test("rate limits creation churn and prunes expired history", () => {
    let state = empty;
    for (let index = 0; index < MAX_SHARE_CREATIONS_PER_MINUTE; index += 1) {
      const result = reserveOwnerShare(state, `share-${index}`, index + 2, index + 1);
      expect(result.ok).toBe(true);
      state = result.state;
    }
    expect(reserveOwnerShare(state, "fast", 100_000, 20)).toMatchObject({
      ok: false,
      error: "create_rate_limited",
    });
    expect(reserveOwnerShare(state, "later", 200_000, 70_001).ok).toBe(true);
  });
});
