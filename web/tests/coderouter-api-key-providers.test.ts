import { afterAll, beforeAll, beforeEach, describe, expect, mock, test } from "bun:test";
import { randomBytes } from "node:crypto";
import {
  decryptCredential,
  encryptCredential,
  type CredentialKeyService,
} from "../services/coderouter/encryption";
import { bindingProvider, createSessionAccountSelector } from "../services/coderouter/repository";
import { apiKeyFingerprint, parseCredential } from "../services/coderouter/accounts";
import {
  CodeRouterCredentialBroken,
  createCredentialRefresher,
  type CredentialRefreshDependencies,
} from "../services/coderouter/refresh";
import type { EncryptedCredential } from "../services/coderouter/encryption";
import {
  credentialExpiresAt,
  credentialLabel,
  maskApiKey,
  type ApiKeyCredential,
  type CodeRouterCredential,
} from "../services/coderouter/types";

type UpstreamCall = { url: string; headers: Headers; body: string };
let upstreamCalls: UpstreamCall[] = [];
let upstreamStatuses: number[] = [];
let accountsToServe: { id: string; credential: CodeRouterCredential }[] = [];
let cooldowns: { accountId: string; durationMs: number }[] = [];
let forcedRefreshes: string[] = [];

const originalFetch = globalThis.fetch;
beforeAll(() => {
  globalThis.fetch = mock(async (...args: unknown[]) => {
    const input = args[0] as string | URL | Request;
    const init = args[1] as RequestInit | undefined;
    const request = input instanceof Request ? input : new Request(input, init);
    upstreamCalls.push({
      url: request.url,
      headers: request.headers,
      body: request.method === "POST" ? await request.text() : "",
    });
    const status = upstreamStatuses.shift() ?? 200;
    return new Response("data: done\n\n", {
      status,
      headers: { "content-type": "text/event-stream" },
    });
  }) as typeof fetch;
});
afterAll(() => {
  globalThis.fetch = originalFetch;
});

const { createCodexModelsProxy, createCodexResponsesProxy, openRouterModelId } = await import(
  "../services/coderouter/codexProxy"
);

const openAiKey: ApiKeyCredential = {
  provider: "openai-apikey",
  apiKey: "sk-proj-0123456789abcdef0123456789abcdef",
  accountId: "fp-openai",
  label: "team openai",
};
const openRouterKey: ApiKeyCredential = {
  provider: "openrouter-apikey",
  apiKey: "sk-or-v1-0123456789abcdef0123456789abcdef",
  accountId: "fp-openrouter",
  label: "",
};
const codexSignIn: CodeRouterCredential = {
  provider: "codex",
  accessToken: "codex-access",
  refreshToken: "codex-refresh",
  idToken: "codex-id",
  accountId: "chatgpt-account",
  email: "person@example.com",
  expiresAt: Date.now() + 60_000,
};

const authenticate = async () => ({ teamId: "team-1", stackUserId: "user-1", vmId: null });
const credentialFor = () => {
  const served = accountsToServe.find((account) => account.id === lastSelected);
  if (!served) throw new Error("no credential for account");
  return served.credential;
};
let lastSelected = "";
const nextAccount = () => {
  const next = accountsToServe[selectIndex++];
  if (!next) return null;
  lastSelected = next.id;
  return { id: next.id, provider: next.credential.provider, vaultRevision: 1, credentialExpiresAt: null };
};
let selectIndex = 0;

const responses = createCodexResponsesProxy({
  authenticate,
  select: async () => {
    const account = nextAccount();
    return account ? { ...account, sticky: false } : null;
  },
  credential: async (input) => {
    const credential = credentialFor();
    if (input.force) {
      forcedRefreshes.push(input.accountId);
      if (credential.provider === "openai-apikey" || credential.provider === "openrouter-apikey") {
        // What the real refresher does: mark the key broken, then throw.
        throw new CodeRouterCredentialBroken("provider rejected the API key");
      }
    }
    return credential;
  },
  cooldown: async (accountId, durationMs) => {
    cooldowns.push({ accountId, durationMs });
  },
});

const models = createCodexModelsProxy({
  authenticate,
  select: async () => nextAccount(),
  credential: async (input) => {
    const credential = credentialFor();
    if (input.force) {
      forcedRefreshes.push(input.accountId);
      throw new CodeRouterCredentialBroken("provider rejected the API key");
    }
    return credential;
  },
  cooldown: async () => {},
  providerRead: async (request) => await request(),
});

beforeEach(() => {
  upstreamCalls = [];
  upstreamStatuses = [];
  accountsToServe = [];
  cooldowns = [];
  forcedRefreshes = [];
  selectIndex = 0;
  lastSelected = "";
});

function responsesRequest(body: unknown = { model: "gpt-5.3-codex", input: [] }): Request {
  return new Request("https://coderouter.dev/v1/responses", {
    method: "POST",
    headers: {
      authorization: "Bearer crt_token",
      "content-type": "application/json",
      session_id: "session-1",
      "openai-beta": "responses=experimental",
    },
    body: JSON.stringify(body),
  });
}

describe("API key credentials", () => {
  test("parses a pasted key into a fingerprinted account with no secret in the id", () => {
    const parsed = parseCredential({
      provider: "openrouter-apikey",
      apiKey: "  sk-or-v1-0123456789abcdef0123456789abcdef ",
      label: " personal ",
    });
    expect(parsed).toEqual({
      provider: "openrouter-apikey",
      apiKey: "sk-or-v1-0123456789abcdef0123456789abcdef",
      accountId: apiKeyFingerprint("openrouter-apikey", "sk-or-v1-0123456789abcdef0123456789abcdef"),
      label: "personal",
    });
    expect(parsed?.accountId).not.toContain("sk-or");
    expect(parsed?.accountId).toHaveLength(24);
  });

  test("rejects short, malformed, or mistyped keys", () => {
    expect(parseCredential({ provider: "openai-apikey", apiKey: "short" })).toBeNull();
    expect(parseCredential({ provider: "openai-apikey", apiKey: "sk-proj-with spaces inside the key" })).toBeNull();
    expect(parseCredential({ provider: "openai-apikey", apiKey: 42 })).toBeNull();
    expect(parseCredential({ provider: "openai-apikey", apiKey: "sk-proj-0123456789abcdef", label: 1 })).toBeNull();
    expect(parseCredential({ provider: "anthropic-apikey", apiKey: "sk-ant-0123456789abcdef" })).toBeNull();
  });

  test("labels fall back to a masked key and API keys never expire", () => {
    expect(credentialLabel(openAiKey)).toBe("team openai");
    expect(credentialLabel(openRouterKey)).toBe("sk-or-v1-…cdef");
    expect(maskApiKey("sk-proj-0123456789abcdef0123456789abcdef")).toBe("sk-proj-…cdef");
    expect(credentialExpiresAt(openAiKey)).toBeNull();
    expect(credentialExpiresAt(codexSignIn)).toBeInstanceOf(Date);
  });

  test("the refresher returns an API key as-is, and a forced refresh marks the account broken", async () => {
    let claims = 0;
    let failed: { terminal: boolean; code: string } | null = null;
    const envelope: EncryptedCredential = {
      accountId: "00000000-0000-4000-8000-000000000001",
      teamId: "team-1",
      provider: "openai-apikey",
      credentialRevision: 1,
      algorithm: "aes-256-gcm",
      ciphertext: "c",
      nonce: "n",
      authTag: "t",
      encryptedDataKey: "k",
      kmsKeyId: "kms",
    };
    const dependencies: CredentialRefreshDependencies = {
      read: async () => ({ envelope, credential: openAiKey }),
      decrypt: async () => openAiKey,
      claim: async () => {
        claims += 1;
        return "lease";
      },
      release: async () => {},
      refresh: async (credential) => credential,
      encrypt: async () => envelope,
      complete: async () => {},
      fail: async (_accountId, _leaseId, terminal, code) => {
        failed = { terminal, code };
      },
      isTerminal: () => false,
      failureCode: () => "n/a",
    };
    const refresh = createCredentialRefresher(dependencies);
    expect(await refresh({ teamId: "team-1", accountId: envelope.accountId, expectedRevision: 1 })).toBe(openAiKey);
    expect(claims).toBe(0);
    await expect(
      refresh({ teamId: "team-1", accountId: envelope.accountId, expectedRevision: 1, force: true }),
    ).rejects.toBeInstanceOf(CodeRouterCredentialBroken);
    expect(claims).toBe(1);
    expect(failed).toEqual({ terminal: true, code: "api_key_rejected" });
  });
});

describe("API key storage and placement", () => {
  test("an API key credential round-trips through the KMS envelope", async () => {
    const dataKey = randomBytes(32);
    const keys: CredentialKeyService = {
      async generateDataKey() {
        return { plaintext: Buffer.from(dataKey), encrypted: Buffer.from(dataKey) };
      },
      async decryptDataKey() {
        return Buffer.from(dataKey);
      },
    };
    const encrypted = await encryptCredential({
      accountId: "00000000-0000-4000-8000-000000000002",
      teamId: "team-1",
      provider: "openrouter-apikey",
      credentialRevision: 1,
      credential: openRouterKey,
      keyId: "test-key",
      keys,
    });
    expect(JSON.stringify(encrypted)).not.toContain(openRouterKey.apiKey);
    expect(await decryptCredential(encrypted, keys)).toEqual(openRouterKey);
  });

  test("a pooled surface keeps one binding row per session under its first provider", async () => {
    expect(bindingProvider(["codex", "openai-apikey", "openrouter-apikey"])).toBe("codex");
    expect(bindingProvider("opencode-go")).toBe("opencode-go");
    const bindCalls: unknown[][] = [];
    const select = createSessionAccountSelector({
      sweepLeases: async () => {},
      findBound: async () => null,
      claim: async () => ({
        id: "acct-or",
        provider: "openrouter-apikey" as const,
        vaultRevision: 1,
        credentialExpiresAt: null,
      }),
      bind: async (...args: unknown[]) => {
        bindCalls.push(args);
      },
    });
    await select({
      teamId: "team-1",
      provider: ["codex", "openai-apikey", "openrouter-apikey"],
      sessionKey: "session-1",
    });
    // The placed account is an OpenRouter key, but the row is stored under the
    // surface's provider so a later move back to Codex replaces it.
    expect(bindCalls).toEqual([["team-1", "codex", "session-1", "acct-or", undefined]]);
  });
});

describe("responses routing through API keys", () => {
  test("sends an OpenAI key to api.openai.com with a bearer header and no ChatGPT account header", async () => {
    accountsToServe = [{ id: "acct-openai", credential: openAiKey }];
    const response = await responses(responsesRequest());
    expect(response.status).toBe(200);
    expect(upstreamCalls).toHaveLength(1);
    const call = upstreamCalls[0]!;
    expect(call.url).toBe("https://api.openai.com/v1/responses");
    expect(call.headers.get("authorization")).toBe(`Bearer ${openAiKey.apiKey}`);
    expect(call.headers.get("chatgpt-account-id")).toBeNull();
    expect(call.headers.get("session_id")).toBeNull();
    expect(call.headers.get("openai-beta")).toBe("responses=experimental");
    expect(JSON.parse(call.body)).toEqual({ model: "gpt-5.3-codex", input: [] });
  });

  test("sends an OpenRouter key to openrouter.ai and vendor-prefixes a bare model id", async () => {
    accountsToServe = [{ id: "acct-or", credential: openRouterKey }];
    const response = await responses(responsesRequest({ model: "gpt-5.3-codex", input: [], store: false }));
    expect(response.status).toBe(200);
    const call = upstreamCalls[0]!;
    expect(call.url).toBe("https://openrouter.ai/api/v1/responses");
    expect(call.headers.get("authorization")).toBe(`Bearer ${openRouterKey.apiKey}`);
    expect(call.headers.get("x-title")).toBe("cmux coderouter");
    expect(call.headers.get("openai-beta")).toBeNull();
    expect(JSON.parse(call.body)).toEqual({ model: "openai/gpt-5.3-codex", input: [], store: false });
  });

  test("keeps a vendor-prefixed model id untouched for OpenRouter", () => {
    expect(openRouterModelId("anthropic/claude-sonnet-4")).toBe("anthropic/claude-sonnet-4");
    expect(openRouterModelId("gpt-5")).toBe("openai/gpt-5");
  });

  test("a Codex sign-in in the same pool still goes to the ChatGPT backend", async () => {
    accountsToServe = [{ id: "acct-codex", credential: codexSignIn }];
    await responses(responsesRequest());
    const call = upstreamCalls[0]!;
    expect(call.url).toBe("https://chatgpt.com/backend-api/codex/responses");
    expect(call.headers.get("chatgpt-account-id")).toBe("chatgpt-account");
  });

  test("a rejected API key is treated as broken and the request fails over", async () => {
    accountsToServe = [
      { id: "acct-or", credential: openRouterKey },
      { id: "acct-codex", credential: codexSignIn },
    ];
    upstreamStatuses = [401, 200];
    const response = await responses(responsesRequest());
    expect(response.status).toBe(200);
    expect(forcedRefreshes).toEqual(["acct-or"]);
    expect(cooldowns).toEqual([]);
    expect(upstreamCalls.map((call) => new URL(call.url).host)).toEqual(["openrouter.ai", "chatgpt.com"]);
  });

  test("model discovery fails over when a key is rejected", async () => {
    accountsToServe = [
      { id: "acct-or", credential: openRouterKey },
      { id: "acct-openai", credential: openAiKey },
    ];
    upstreamStatuses = [401, 200];
    const listed = await models(new Request("https://coderouter.dev/v1/models", {
      headers: { authorization: "Bearer crt_route" },
    }));
    expect(listed.status).toBe(200);
    expect(forcedRefreshes).toEqual(["acct-or"]);
    expect(upstreamCalls.map((call) => new URL(call.url).host)).toEqual(["openrouter.ai", "api.openai.com"]);
  });

  test("model discovery uses each provider's own catalog", async () => {
    accountsToServe = [{ id: "acct-or", credential: openRouterKey }];
    const listed = await models(new Request("https://coderouter.dev/v1/models?client_version=1", {
      headers: { authorization: "Bearer crt_route" },
    }));
    expect(listed.status).toBe(200);
    expect(upstreamCalls[0]!.url).toBe("https://openrouter.ai/api/v1/models");
    expect(upstreamCalls[0]!.headers.get("authorization")).toBe(`Bearer ${openRouterKey.apiKey}`);
  });
});
