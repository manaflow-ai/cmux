import { describe, expect, mock, test } from "bun:test";
import {
  credentialForMirror,
  mirrorConnectedAccount,
  mirroredProviderAccountId,
  unmirrorConnectedAccount,
  type MirrorDependencies,
} from "../services/coderouter/accountMirror";

// Every account connected through the existing app/dashboard path (Subrouter)
// is mirrored into the coderouter vault the cloud machines route through, and
// un-mirrored on removal. Never fatal to the connect itself.

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
    add: mock(async () => ({ accountId: "vault-1", alreadyExists: false, refreshed: false })),
    find: mock(async () => null),
    remove: mock(async () => ({ removed: true, lastAccount: false })),
    report: mock((error: unknown) => {
      reports.push(error);
    }) as unknown as MirrorDependencies["report"],
    additionAllowed: mock(async () => ({ allowed: true })) as unknown as MirrorDependencies["additionAllowed"],
    hostedProRequired: () => false,
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

  test("an unlabeled connect never stores an empty email (the decrypt parser would reject it)", () => {
    const unlabeled = { ...claudeInput, label: undefined };
    expect(credentialForMirror(unlabeled, { id: "sr-2", kind: "claude", label: null })?.email)
      .toBe("subrouter:sr-2");
    expect(credentialForMirror(unlabeled, { id: "sr-2", kind: "claude", label: "  " })?.email)
      .toBe("subrouter:sr-2");
    expect(credentialForMirror(claudeInput, { id: "sr-2", kind: "claude" })?.email)
      .toBe("person@example.com");
  });

  test("maps a connected ChatGPT login onto the vault's codex credential", () => {
    const idToken = fakeJwt({ email: "chatgpt@example.com" });
    const accessToken = fakeJwt({ exp: 1_800_000_000 });
    expect(
      credentialForMirror(
        {
          provider: "codex",
          tokens: { accessToken, refreshToken: "r", idToken, accountID: "chatgpt-acct-9" },
        },
        { id: "c", kind: "codex" },
      ),
    ).toEqual({
      provider: "codex",
      accessToken,
      refreshToken: "r",
      idToken,
      // The vault identity is the app-side account, so a disconnect can find
      // it; the ChatGPT account id still rides upstream.
      accountId: "subrouter:c",
      chatgptAccountId: "chatgpt-acct-9",
      email: "chatgpt@example.com",
      expiresAt: 1_800_000_000_000,
    });
  });

  test("a ChatGPT login without readable claims falls back to the label and refreshes on first use", () => {
    const before = Date.now();
    const mapped = credentialForMirror(
      {
        provider: "codex",
        label: "work chatgpt",
        tokens: { accessToken: "opaque", refreshToken: "r", idToken: "opaque", accountID: "acct" },
      },
      { id: "c2", kind: "codex", label: null },
    );
    expect(mapped.provider).toBe("codex");
    expect(mapped.email).toBe("work chatgpt");
    if (mapped.provider === "codex") expect(mapped.expiresAt).toBeGreaterThanOrEqual(before);
  });

  test("maps provider API keys onto the key kinds", () => {
    expect(
      credentialForMirror(
        { provider: "anthropic-apikey", apiKey: "sk-ant-api", label: "work" },
        { id: "k", kind: "anthropic-apikey", label: "work" },
      ),
    ).toEqual({ provider: "anthropic-apikey", apiKey: "sk-ant-api", accountId: "subrouter:k", email: "work" });
    expect(
      credentialForMirror(
        { provider: "openai-apikey", apiKey: "sk-openai" },
        { id: "o", kind: "openai-apikey" },
      ),
    ).toEqual({ provider: "openai-apikey", apiKey: "sk-openai", accountId: "subrouter:o", email: "subrouter:o" });
  });
});

function fakeJwt(payload: Record<string, unknown>): string {
  const encode = (value: unknown) => Buffer.from(JSON.stringify(value)).toString("base64url");
  return `${encode({ alg: "none" })}.${encode(payload)}.sig`;
}

describe("mirrorConnectedAccount", () => {
  test("adds the claude credential to the team vault", async () => {
    const d = deps();
    const outcome = await mirrorConnectedAccount(
      { teamId: "team-1", stackUserId: "user-1", input: claudeInput, created },
      d,
    );
    expect(outcome).toBe("mirrored");
    expect(d.add).toHaveBeenCalledWith(
      "team-1",
      expect.objectContaining({ provider: "claude", accountId: "subrouter:sr-acct-1" }),
      { refreshExisting: true },
    );
  });

  test("a re-connect refreshes the vault copy with the rotated tokens", async () => {
    const d = deps({
      add: mock(async () => ({ accountId: "vault-1", alreadyExists: true, refreshed: true })),
    });
    expect(await mirrorConnectedAccount({ teamId: "team-1", stackUserId: "user-1", input: claudeInput, created }, d))
      .toBe("refreshed");
  });

  test("a vault failure is reported and never thrown", async () => {
    const d = deps({
      add: mock(async () => {
        throw new Error("kms down");
      }),
    });
    expect(await mirrorConnectedAccount({ teamId: "team-1", stackUserId: "user-1", input: claudeInput, created }, d))
      .toBe("failed");
    expect(d.reports).toHaveLength(1);
  });

  test("the hosted account limit applies to mirroring too", async () => {
    const d = deps({
      hostedProRequired: () => true,
      additionAllowed: mock(async () => ({ allowed: false })) as unknown as MirrorDependencies["additionAllowed"],
    });
    expect(await mirrorConnectedAccount({ teamId: "team-1", stackUserId: "user-1", input: claudeInput, created }, d))
      .toBe("limit_reached");
    expect(d.add).not.toHaveBeenCalled();
    expect(d.additionAllowed).toHaveBeenCalledWith({
      stackUserId: "user-1",
      teamId: "team-1",
      provider: "claude",
      providerAccountId: "subrouter:sr-acct-1",
    });
  });

  test("an allowed gate lets the mirror through", async () => {
    const d = deps({ hostedProRequired: () => true });
    expect(await mirrorConnectedAccount({ teamId: "team-1", stackUserId: "user-1", input: claudeInput, created }, d))
      .toBe("mirrored");
  });

  test("an API key upload is mirrored as a key kind", async () => {
    const d = deps();
    const outcome = await mirrorConnectedAccount(
      {
        teamId: "team-1",
        stackUserId: "user-1",
        input: { provider: "openai-apikey", apiKey: "sk-openai" },
        created: { id: "o", kind: "openai-apikey" },
      },
      d,
    );
    expect(outcome).toBe("mirrored");
    expect(d.add).toHaveBeenCalledWith(
      "team-1",
      { provider: "openai-apikey", apiKey: "sk-openai", accountId: "subrouter:o", email: "subrouter:o" },
      { refreshExisting: true },
    );
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

  test("finds a mirror of any kind, not just Claude", async () => {
    const find = mock(async (...args: unknown[]) =>
      args[1] === "openai-apikey" ? { id: "vault-key", state: "active", vaultRevision: 1 } : null,
    ) as unknown as MirrorDependencies["find"];
    const d = deps({ find });
    expect(await unmirrorConnectedAccount({ teamId: "team-1", subrouterAccountId: "o" }, d)).toBe("removed");
    expect(d.remove).toHaveBeenCalledWith({ teamId: "team-1", accountId: "vault-key" });
    expect((find as unknown as { mock: { calls: unknown[][] } }).mock.calls.map((call) => call[1]))
      .toEqual(["claude", "codex", "anthropic-apikey", "openai-apikey"]);
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
