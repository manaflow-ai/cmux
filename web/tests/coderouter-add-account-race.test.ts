import { beforeEach, expect, mock, test } from "bun:test";
import type { CredentialKeyService } from "../services/coderouter/encryption";
import type { ApiKeyCredential } from "../services/coderouter/types";

// Two imports of the same account can both miss the first lookup. The one
// whose insert loses the uniqueness race reads the winner back, and must
// treat it like a match found up front (#14111).
type Match = { id: string; state: string; vaultRevision: number; visibility: "private" | "team"; createdBy: string | null };
let lookups: (Match | null)[] = [];
const inserts: unknown[] = [];
const unexpected = async () => { throw new Error("unexpected repository call"); };

mock.module("../services/coderouter/repository", () => ({
  findAccountByProviderIdentity: async () => lookups.shift() ?? null,
  insertAccountWithCredential: async (input: unknown) => { inserts.push(input); return false; },
  deleteAccount: unexpected,
  listAccounts: unexpected,
  replaceAccountCredential: unexpected,
  withVaultLease: unexpected,
  bindCodexOwnerIdentity: unexpected,
  encryptedCredentialForAccount: unexpected,
  transferEncryptedAccount: unexpected,
  updateAccountLabel: unexpected,
}));

const { addAccount } = await import("../services/coderouter/accounts");

const TEAM = "race-team";
const ADMIN = "race-admin";
const MEMBER = "race-member";
const member = { createdBy: MEMBER, visibility: "private", access: { kind: "own-private", userId: MEMBER } } as const;
const admin = { createdBy: ADMIN, visibility: "private", access: { kind: "user", userId: ADMIN } } as const;
const keys: CredentialKeyService = {
  async generateDataKey() { return { plaintext: Buffer.alloc(32, 7), encrypted: Buffer.alloc(32, 7) }; },
  async decryptDataKey() { return Buffer.alloc(32, 7); },
};
const noVerify = async () => {};
const credential: ApiKeyCredential = { provider: "openai-apikey", apiKey: "sk-test-not-a-real-key", accountId: "raced", label: "member label" };

function shared(state: string): Match {
  return { id: "shared-account", state, vaultRevision: 1, visibility: "team", createdBy: ADMIN };
}

function raceTo(winner: Match) {
  lookups = [null, winner];
}

beforeEach(() => {
  process.env.CODEROUTER_KMS_KEY_ID = "race-test-key";
  lookups = [];
  inserts.length = 0;
});

test("a member who loses the insert race to an inactive shared account is refused", async () => {
  raceTo(shared("expired"));
  await expect(addAccount(TEAM, credential, keys, noVerify, noVerify, member))
    .rejects.toMatchObject({ name: "CoderouterSharedAccountError" });
  expect(inserts).toHaveLength(1);
});

test("a member who loses the insert race to an active shared account gets it back", async () => {
  raceTo(shared("active"));
  await expect(addAccount(TEAM, credential, keys, noVerify, noVerify, member))
    .resolves.toEqual({ accountId: "shared-account", alreadyExists: true });
});

test("an administrator who loses the insert race gets the winning account back", async () => {
  raceTo(shared("expired"));
  await expect(addAccount(TEAM, credential, keys, noVerify, noVerify, admin))
    .resolves.toEqual({ accountId: "shared-account", alreadyExists: true });
});
