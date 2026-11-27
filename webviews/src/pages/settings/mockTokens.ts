// l10n-allow-file: mock API tokens (sample names, repositories and people); the real ones come from the platform.
// The mock Settings > Developer: state shaped like SettingsDeveloperTokens serves it (`cmux token list
// --json` passed through) and the host's answer to each gesture, so the card and its gallery run with
// no CLI and no platform. Pure data: the gallery imports these fixtures. The tokens here are made up
// (no platform issued them), in the token's shape so the page draws them as it would a real one.
import type { ApiToken, CreatedToken, DeveloperTokensRun, DeveloperTokensState, GithubTokenRule } from "./ops";

// Relative to when the page loads, so the rows read the same ("Used 2 hours ago") whenever they draw.
const NOW = Date.now();
const ago = (ms: number) => new Date(NOW - ms).toISOString();
const ahead = (ms: number) => new Date(NOW + ms).toISOString();
const HOUR = 3_600_000;
const DAY = 24 * HOUR;

export const MOCK_PLATFORM = "https://cmux-platform-production.debussy.workers.dev";
export const MOCK_TEAM = "team_0f3a9c2e7b14d5a86c01";

export const MOCK_TOKEN_DEPLOY: ApiToken = {
  id: "tok_mock_deploy",
  name: "Deploy script",
  display: "cmux_pat_Q7mX…a9Kd",
  scopes: ["machines", "chats"],
  owner: "me",
  source: "personal",
  createdBy: "usr_mock_lena",
  createdByName: "Lena Park",
  createdAt: ago(40 * DAY),
  expiresAt: ahead(50 * DAY),
  lastUsedAt: ago(2 * HOUR),
  spendCapUsd: 50,
};

export const MOCK_TOKEN_USAGE: ApiToken = {
  id: "tok_mock_usage",
  name: "Usage dashboard",
  display: "cmux_pat_Lr2B…7tWc",
  scopes: ["usage"],
  owner: "me",
  source: "personal",
  createdBy: "usr_mock_lena",
  createdByName: "Lena Park",
  createdAt: ago(3 * DAY),
  expiresAt: null,
  lastUsedAt: null,
  spendCapUsd: null,
};

export const MOCK_TOKEN_CI: ApiToken = {
  id: "tok_mock_ci",
  name: "Nightly evals",
  display: "cmux_pat_c4Hn…Pq02",
  scopes: ["machines", "chats", "usage"],
  owner: "team",
  source: "service",
  createdBy: "usr_mock_sam",
  createdByName: "Sam Ortiz",
  createdAt: ago(80 * DAY),
  expiresAt: ahead(285 * DAY),
  lastUsedAt: ago(9 * HOUR),
  spendCapUsd: 200,
};

export const MOCK_GITHUB_RULE: GithubTokenRule = {
  id: "ghr_mock_acme_web",
  repository: "acme/web",
  ref: "refs/heads/main",
  environment: "production",
  scopes: ["machines", "chats"],
  spendCapUsd: null,
  createdAt: ago(12 * DAY),
  createdBy: "usr_mock_sam",
  lastUsedAt: ago(26 * HOUR),
};

/** A made-up token in the platform's shape (`cmux_pat_` + 50 base62). No platform issued it. */
export const MOCK_CREATED_SECRET = "cmux_pat_" + "MockMockMock".padEnd(44, "0") + "0fakeX";

export function mockTokensState(patch: Partial<DeveloperTokensState> = {}): DeveloperTokensState {
  return {
    loading: false,
    problem: null,
    listError: null,
    platform: MOCK_PLATFORM,
    team: null,
    tokens: [MOCK_TOKEN_DEPLOY, MOCK_TOKEN_USAGE],
    canManageTeamTokens: false,
    githubRules: null,
    error: null,
    ...patch,
  };
}

/** The team admin's page: personal and team tokens, one allowed repository. */
export function mockTeamAdminTokensState(): DeveloperTokensState {
  return mockTokensState({
    team: MOCK_TEAM,
    tokens: [MOCK_TOKEN_DEPLOY, MOCK_TOKEN_CI],
    canManageTeamTokens: true,
    githubRules: [MOCK_GITHUB_RULE],
  });
}

/** The host's answer to one gesture: the state after it, and the token a create made. */
export function runMockTokens(
  state: DeveloperTokensState,
  run: DeveloperTokensRun,
): { state: DeveloperTokensState; created: CreatedToken | null } {
  switch (run.action) {
    case "refresh":
      return { state, created: null };
    case "create": {
      const tokenInfo: ApiToken = {
        id: `tok_mock_${state.tokens.length + 1}`,
        name: run.name,
        display: `${MOCK_CREATED_SECRET.slice(0, 13)}…${MOCK_CREATED_SECRET.slice(-4)}`,
        scopes: run.scopes,
        owner: run.owner,
        source: run.owner === "team" ? "service" : "personal",
        createdBy: "usr_mock_lena",
        createdByName: "Lena Park",
        createdAt: new Date(NOW).toISOString(),
        expiresAt: run.expiresInDays === null ? null : ahead(run.expiresInDays * DAY),
        lastUsedAt: null,
        spendCapUsd: run.spendCapUsd ?? null,
      };
      return {
        state: { ...state, error: null, tokens: [tokenInfo, ...state.tokens] },
        created: { token: MOCK_CREATED_SECRET, tokenInfo },
      };
    }
    case "revoke":
      return {
        state: { ...state, error: null, tokens: state.tokens.filter((one) => one.id !== run.id) },
        created: null,
      };
    case "allowRepository": {
      const rule: GithubTokenRule = {
        id: `ghr_mock_${(state.githubRules?.length ?? 0) + 1}`,
        repository: run.repository,
        ...(run.ref ? { ref: run.ref } : {}),
        ...(run.environment ? { environment: run.environment } : {}),
        scopes: run.scopes,
        spendCapUsd: null,
        createdAt: new Date(NOW).toISOString(),
        createdBy: "usr_mock_lena",
        lastUsedAt: null,
      };
      return { state: { ...state, error: null, githubRules: [...(state.githubRules ?? []), rule] }, created: null };
    }
    case "removeRepository":
      return {
        state: { ...state, error: null, githubRules: (state.githubRules ?? []).filter((one) => one.id !== run.id) },
        created: null,
      };
  }
}
