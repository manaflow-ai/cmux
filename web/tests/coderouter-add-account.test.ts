import { describe, expect, test } from "bun:test";
import { createAccountAdder } from "../services/coderouter/accounts";
import type { EncryptedCredential } from "../services/coderouter/encryption";
import type { ClaudeCredential } from "../services/coderouter/types";

const credential: ClaudeCredential = {
  provider: "claude",
  accessToken: "access",
  refreshToken: "refresh",
  accountId: "acct-claude-1",
  email: "person@example.com",
  expiresAt: Date.now() + 60_000,
};

const encrypted = {} as EncryptedCredential;

function adder(input: {
  readonly existing: { id: string; state: string; vaultRevision: number } | null;
}) {
  const calls = { inserted: 0, replaced: 0 };
  const add = createAccountAdder({
    find: async () => input.existing,
    encrypt: async () => encrypted,
    insert: async () => {
      calls.inserted += 1;
      return true;
    },
    replace: async () => {
      calls.replaced += 1;
    },
  });
  return { add, calls };
}

describe("coderouter addAccount", () => {
  test("a brand-new account is inserted and reported as new", async () => {
    const { add, calls } = adder({ existing: null });
    const result = await add("team-1", credential);
    expect(result).toMatchObject({ alreadyExists: false, refreshed: false });
    expect(calls).toEqual({ inserted: 1, replaced: 0 });
  });

  test("a healthy account is left untouched unless the caller asks to refresh it", async () => {
    const { add, calls } = adder({
      existing: { id: "acct-existing", state: "active", vaultRevision: 3 },
    });
    const result = await add("team-1", credential);
    expect(result).toEqual({ accountId: "acct-existing", alreadyExists: true, refreshed: false });
    expect(calls).toEqual({ inserted: 0, replaced: 0 });
  });

  test("refreshExisting replaces a healthy account's credential and reports it refreshed", async () => {
    const { add, calls } = adder({
      existing: { id: "acct-existing", state: "refreshing", vaultRevision: 3 },
    });
    const result = await add("team-1", credential, { refreshExisting: true });
    expect(result).toEqual({ accountId: "acct-existing", alreadyExists: true, refreshed: true });
    expect(calls).toEqual({ inserted: 0, replaced: 1 });
  });

  // `cr add` on an account the vault marked expired or broken is a repair: the
  // credential is replaced, and the caller (and its 201) sees a new connection,
  // exactly as before the connected-account mirror was added.
  for (const state of ["expired", "broken"]) {
    test(`repairing a ${state} account replaces the credential and is reported as new`, async () => {
      const { add, calls } = adder({
        existing: { id: "acct-existing", state, vaultRevision: 3 },
      });
      const result = await add("team-1", credential);
      expect(result).toEqual({ accountId: "acct-existing", alreadyExists: false, refreshed: false });
      expect(calls).toEqual({ inserted: 0, replaced: 1 });
    });
  }

  test("the mirror repairing an expired account reports it refreshed, not already connected", async () => {
    const { add, calls } = adder({
      existing: { id: "acct-existing", state: "expired", vaultRevision: 3 },
    });
    const result = await add("team-1", credential, { refreshExisting: true });
    expect(result).toEqual({ accountId: "acct-existing", alreadyExists: false, refreshed: true });
    expect(calls).toEqual({ inserted: 0, replaced: 1 });
  });
});
