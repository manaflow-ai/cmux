import { expect, test } from "bun:test";
import { userMessage } from "../shared/userMessage";
import { SETTINGS_SENTENCES, type CreatedToken, type DeveloperTokensState, type SettingsClient } from "./ops";
import { SettingsStore } from "./store";

function listedState(): DeveloperTokensState {
  return {
    loading: false,
    problem: null,
    listError: null,
    platform: "https://api.example.com",
    team: "team_example",
    tokens: [],
    canManageTeamTokens: true,
    githubRules: [],
    error: null,
  };
}

function clientFor(run: () => unknown, state: () => unknown): SettingsClient {
  return {
    async call<R>(op: string): Promise<R> {
      if (op === "cmux.settings.tokens.run") return run() as R;
      if (op === "cmux.settings.tokens.state") return state() as R;
      throw new Error(`Unexpected operation: ${op}`);
    },
    async subscribe() {
      return () => {};
    },
  };
}

test("a rejected token gesture reaches the card without changing the listed state", async () => {
  const state = listedState();
  const error = { code: "cmux.page.invalid_params", message: "ref must be one line" };
  const store = new SettingsStore(
    clientFor(
      () => {
        throw error;
      },
      () => state,
    ),
  );
  try {
    const result = await store.runTokens({
      action: "allowRepository",
      repository: "example/repo",
      ref: "main\nother",
      scopes: ["machines"],
    });
    expect(result.ok).toBe(false);
    expect(result.created).toBeNull();
    expect(result.state).toEqual({
      ...state,
      error: { action: "allowRepository", code: error.code, message: userMessage(error, SETTINGS_SENTENCES) },
    });
    expect(state.error).toBeNull();
  } finally {
    store.dispose();
  }
});

test("a disconnected host preserves the gesture error with management unavailable", async () => {
  const error = { code: "cmux.protocol.closed", message: "socket details" };
  const fail = () => {
    throw error;
  };
  const store = new SettingsStore(clientFor(fail, fail));
  try {
    const result = await store.runTokens({ action: "revoke", id: "token_example" });
    expect(result.ok).toBe(false);
    expect(result.created).toBeNull();
    expect(result.state).toEqual({
      loading: false,
      problem: "unavailable",
      listError: null,
      platform: null,
      team: null,
      tokens: [],
      canManageTeamTokens: false,
      githubRules: null,
      error: { action: "revoke", code: error.code, message: userMessage(error, SETTINGS_SENTENCES) },
    });
    expect(result.state?.error?.message).not.toContain("socket details");
  } finally {
    store.dispose();
  }
});

test("a successful create returns its secret once outside the refreshed state", async () => {
  const state = listedState();
  const created: CreatedToken = { token: "cmux_pat_test_secret", tokenInfo: { scopes: ["machines"] } };
  let creates = 0;
  const store = new SettingsStore(
    clientFor(
      () => (creates++ === 0 ? { ok: true, created } : {}),
      () => state,
    ),
  );
  try {
    const result = await store.runTokens({
      action: "create",
      name: "deploy",
      scopes: ["machines"],
      expiresInDays: 30,
      owner: "me",
    });
    expect(result).toEqual({ ok: true, state, created });
    expect(JSON.stringify(result.state)).not.toContain(created.token);
    expect(await store.runTokens({ action: "refresh" })).toEqual({ ok: true, state, created: null });
  } finally {
    store.dispose();
  }
});

test("a CLI refusal retains the provider's action error", async () => {
  const state = listedState();
  state.error = { action: "revoke", code: "token.not_found", message: "Token no longer exists" };
  const store = new SettingsStore(
    clientFor(
      () => ({ ok: false }),
      () => state,
    ),
  );
  try {
    expect(await store.runTokens({ action: "revoke", id: "token_example" })).toEqual({
      ok: false,
      state,
      created: null,
    });
  } finally {
    store.dispose();
  }
});
