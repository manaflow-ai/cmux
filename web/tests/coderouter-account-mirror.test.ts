import { describe, expect, mock, test } from "bun:test";
import {
  credentialForMirror,
  mirrorConnectedAccount,
  mirroredProviderAccountId,
  unmirrorConnectedAccount,
  type MirrorDependencies,
} from "../services/coderouter/accountMirror";

// A Claude account connected through the existing app/dashboard path
// (Subrouter) is mirrored into the coderouter vault the cloud machines route
// through, and un-mirrored on removal. Never fatal to the connect itself.

const claudeInput = {
  provider: "claude" as const,
  label: "person@example.com",
  claudeAiOauth: {
    accessToken: "sk-ant-oat-access",
    refreshToken: "sk-ant-ort-refresh",
    expiresAt: 1_800_000_000_000,
    subscriptionType: "max",
  },
};
const created = { id: "sr-acct-1", kind: "claude", label: "person@example.com" };

function deps(overrides: Partial<MirrorDependencies> = {}): MirrorDependencies & {
  readonly reports: unknown[];
} {
  const reports: unknown[] = [];
  return {
    add: mock(async () => ({ accountId: "vault-1", alreadyExists: false })),
    find: mock(async () => null),
    remove: mock(async () => ({ removed: true, lastAccount: false })),
    report: mock((error: unknown) => {
      reports.push(error);
    }) as unknown as MirrorDependencies["report"],
    reports,
    ...overrides,
  };
}

describe("credentialForMirror", () => {
  test("maps a connected Claude login onto the vault's claude credential", () => {
    expect(credentialForMirror(claudeInput, created)).toEqual({
      provider: "claude",
      accessToken: "sk-ant-oat-access",
      refreshToken: "sk-ant-ort-refresh",
      accountId: mirroredProviderAccountId("sr-acct-1"),
      email: "person@example.com",
      expiresAt: 1_800_000_000_000,
      subscriptionType: "max",
    });
    expect(mirroredProviderAccountId("sr-acct-1")).toBe("subrouter:sr-acct-1");
  });

  test("has no vault mapping for API-key or Codex uploads", () => {
    expect(
      credentialForMirror(
        { provider: "anthropic-apikey", apiKey: "sk-ant-api" },
        { id: "k", kind: "anthropic-apikey" },
      ),
    ).toBeNull();
    expect(
      credentialForMirror(
        {
          provider: "codex",
          tokens: { accessToken: "a", refreshToken: "r", idToken: "i", accountID: "acct" },
        },
        { id: "c", kind: "codex" },
      ),
    ).toBeNull();
  });
});

describe("mirrorConnectedAccount", () => {
  test("adds the claude credential to the team vault", async () => {
    const d = deps();
    const outcome = await mirrorConnectedAccount(
      { teamId: "team-1", input: claudeInput, created },
      d,
    );
    expect(outcome).toBe("mirrored");
    expect(d.add).toHaveBeenCalledWith("team-1", expect.objectContaining({
      provider: "claude",
      accountId: "subrouter:sr-acct-1",
    }));
  });

  test("reports an idempotent re-connect as already mirrored", async () => {
    const d = deps({ add: mock(async () => ({ accountId: "vault-1", alreadyExists: true })) });
    expect(await mirrorConnectedAccount({ teamId: "team-1", input: claudeInput, created }, d))
      .toBe("already_mirrored");
  });

  test("a vault failure is reported and never thrown", async () => {
    const d = deps({
      add: mock(async () => {
        throw new Error("kms down");
      }),
    });
    expect(await mirrorConnectedAccount({ teamId: "team-1", input: claudeInput, created }, d))
      .toBe("failed");
    expect(d.reports).toHaveLength(1);
  });

  test("non-claude uploads are not applicable and touch nothing", async () => {
    const d = deps();
    const outcome = await mirrorConnectedAccount(
      {
        teamId: "team-1",
        input: { provider: "openai-apikey", apiKey: "sk-openai" },
        created: { id: "o", kind: "openai-apikey" },
      },
      d,
    );
    expect(outcome).toBe("not_applicable");
    expect(d.add).not.toHaveBeenCalled();
  });
});

describe("unmirrorConnectedAccount", () => {
  test("removes the mirrored vault account by its subrouter identity", async () => {
    const d = deps({
      find: mock(async () => ({ id: "vault-1", state: "active", vaultRevision: 1 })) as unknown as MirrorDependencies["find"],
    });
    expect(await unmirrorConnectedAccount({ teamId: "team-1", subrouterAccountId: "sr-acct-1" }, d))
      .toBe("removed");
    expect(d.find).toHaveBeenCalledWith("team-1", "claude", "subrouter:sr-acct-1");
    expect(d.remove).toHaveBeenCalledWith({ teamId: "team-1", accountId: "vault-1" });
  });

  test("an account that was never mirrored is a no-op", async () => {
    const d = deps();
    expect(await unmirrorConnectedAccount({ teamId: "team-1", subrouterAccountId: "sr-x" }, d))
      .toBe("not_mirrored");
    expect(d.remove).not.toHaveBeenCalled();
  });

  test("a vault failure is reported and never thrown", async () => {
    const d = deps({
      find: mock(async () => {
        throw new Error("rds down");
      }) as unknown as MirrorDependencies["find"],
    });
    expect(await unmirrorConnectedAccount({ teamId: "team-1", subrouterAccountId: "sr-x" }, d))
      .toBe("failed");
    expect(d.reports).toHaveLength(1);
  });
});
