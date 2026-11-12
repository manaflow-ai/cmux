// l10n-allow-file: agent CLI output and daemon rows the mock serves, never page copy.
//
// The first-user journey matrix's cells (webviews/scripts/first-user-journey): one harness in one of
// four states, every other harness absent, on a machine with no chats yet. The mock daemon (mock.ts)
// and the Settings mock (pages/settings/main.tsx) read the cell from `?mock&journey=HARNESS:STATE`
// (or `globalThis.cmuxAcpmuxMockJourney`) and serve what the real daemon serves in that state:
//
//   not-installed  no profile and no health row (acpmux lists only harnesses it found or was given);
//                  the picker still lists a catalog harness as not installed. `session/new` on it
//                  fails with config.rs's "unknown harness" text.
//   signed-out     a profile and a health row with `auth: "signedOut"`; a turn fails with the CLI's
//                  own sign-in refusal (Claude's "Not logged in · Please run /login", which acpmux
//                  types `auth.signed_out` with recovery.rs's recovery; ACP adapters' "Authentication
//                  required", which acpmux leaves untyped).
//   expired        signed in, but the plan is spent: a turn fails with the provider's usage-limit text
//                  (Claude Code's "You've hit your limit · resets …", Codex's "You've hit your usage
//                  limit. Upgrade to Plus …"), untyped, as hub/turn_errors.rs sees them.
//   working        signed in; a turn streams the mock's scripted reply.
//
// The Claude and Codex texts are the ones acpmux's own tests record (hub/turn_errors.rs, recovery.rs,
// tests/fake_agent.py); the other CLIs' are their published wording where known, else the ACP standard
// `auth_required` message their adapters send.

export const JOURNEY_STATES = ["not-installed", "signed-out", "expired", "working"] as const;
export type JourneyState = (typeof JOURNEY_STATES)[number];
export type JourneyCell = { harness: string; state: JourneyState };

type Known = {
  name: string;
  /** The program acpmux runs (config/discover.rs), shown in health rows. */
  program: string;
  channel: "npm" | "bun" | "brew" | "native" | "standalone";
  package?: string;
  /** harness_health/mod.rs `builtin_login` (null where acpmux knows none). */
  login: string | null;
  kind: "acp" | "claude-stdio";
  models: { id: string; name: string }[];
  /** The CLI's refusal when it has no sign-in. */
  signedOut: string;
  /** The provider's refusal when the plan or quota is spent. */
  limit: string;
};

const AUTH_REQUIRED = "Authentication required";

const KNOWN: Record<string, Known> = {
  claude: {
    name: "Claude Code",
    program: "claude",
    channel: "native",
    package: "@anthropic-ai/claude-code",
    login: "claude auth login",
    kind: "claude-stdio",
    models: [
      { id: "claude-opus-5-5", name: "Opus 5.5" },
      { id: "claude-sonnet-5-5", name: "Sonnet 5.5" },
      { id: "claude-haiku-4-5", name: "Haiku 4.5" },
    ],
    signedOut: "Not logged in · Please run /login",
    limit: "You've hit your limit · resets 3pm (America/Los_Angeles)",
  },
  codex: {
    name: "Codex",
    program: "codex-acp",
    channel: "npm",
    package: "@openai/codex",
    login: "codex login",
    kind: "acp",
    models: [
      { id: "gpt-6.1-sol", name: "GPT-6.1-Sol" },
      { id: "gpt-6-astra", name: "GPT-6-Astra" },
    ],
    signedOut: AUTH_REQUIRED,
    limit:
      "You've hit your usage limit. Upgrade to Plus to continue using Codex (https://chatgpt.com/explore/plus), or try again in 4 days 2 hours 13 minutes.",
  },
  gemini: {
    name: "Gemini CLI",
    program: "gemini",
    channel: "npm",
    package: "@google/gemini-cli",
    login: "gemini",
    kind: "acp",
    models: [
      { id: "gemini-3.1-pro-preview", name: "Gemini 3.1 Pro" },
      { id: "gemini-3-flash", name: "Gemini 3 Flash" },
    ],
    signedOut: AUTH_REQUIRED,
    limit:
      "You have exhausted your daily quota on this model. Quota exceeded for quota metric 'Gemini 3.1 Pro Requests' and limit 'Gemini 3.1 Pro Requests per day per user per tier'.",
  },
  opencode: {
    name: "OpenCode",
    program: "opencode",
    channel: "npm",
    package: "opencode-ai",
    login: "opencode auth login",
    kind: "acp",
    models: [
      { id: "anthropic/claude-sonnet-5-5", name: "Claude Sonnet 5.5" },
      { id: "openai/gpt-6.1-sol", name: "GPT-6.1-Sol" },
    ],
    signedOut: "No provider credentials configured. Run `opencode auth login` to add one.",
    limit: "Insufficient credits: you have used all included usage for this billing period.",
  },
  pi: {
    name: "Pi",
    program: "pi-acp",
    channel: "npm",
    package: "pi-acp",
    login: null,
    kind: "acp",
    models: [
      { id: "anthropic/claude-sonnet-5-5", name: "Claude Sonnet 5.5" },
      { id: "openai/gpt-6.1-sol", name: "GPT-6.1-Sol" },
    ],
    signedOut: AUTH_REQUIRED,
    limit: "429 rate_limit_error: You've reached your usage limit for this account",
  },
  cursor: {
    name: "Cursor",
    program: "cursor-agent",
    channel: "standalone",
    login: null,
    kind: "acp",
    models: [
      { id: "auto", name: "Auto" },
      { id: "sonnet-5.5", name: "Sonnet 5.5" },
    ],
    signedOut: AUTH_REQUIRED,
    limit: "You've hit your usage limit for this billing cycle. Upgrade your plan or enable usage-based pricing.",
  },
  grok: {
    name: "Grok",
    program: "grok",
    channel: "standalone",
    login: null,
    kind: "acp",
    models: [
      { id: "grok-5", name: "Grok 5" },
      { id: "grok-code-fast-2", name: "Grok Code Fast 2" },
    ],
    signedOut: AUTH_REQUIRED,
    limit: "You have reached your usage limit for this plan. Your limit resets in 3 hours.",
  },
  antigravity: {
    name: "Antigravity",
    program: "agy",
    channel: "standalone",
    login: "cmux harness login antigravity",
    kind: "acp",
    models: [
      { id: "gemini-3.1-pro-preview", name: "Gemini 3.1 Pro" },
      { id: "claude-sonnet-5-5", name: "Claude Sonnet 5.5" },
    ],
    signedOut: AUTH_REQUIRED,
    limit: "Quota exceeded: you have used your model quota. It refreshes in 5 hours.",
  },
  hermes: {
    name: "Hermes Agent",
    program: "hermes",
    channel: "standalone",
    login: "hermes model",
    kind: "acp",
    models: [{ id: "hermes-4-405b", name: "Hermes 4 405B" }],
    signedOut: AUTH_REQUIRED,
    limit: "Error code: 429 - insufficient_quota: You exceeded your current quota.",
  },
  deepseek: {
    name: "DeepSeek",
    program: "dsh",
    channel: "standalone",
    login: null,
    kind: "acp",
    models: [{ id: "deepseek-v4", name: "DeepSeek V4" }],
    signedOut: AUTH_REQUIRED,
    limit: "Insufficient Balance",
  },
  omp: {
    name: "oh-my-pi",
    program: "omp",
    channel: "bun",
    package: "oh-my-pi",
    login: null,
    kind: "acp",
    models: [{ id: "anthropic/claude-sonnet-5-5", name: "Claude Sonnet 5.5" }],
    signedOut: AUTH_REQUIRED,
    limit: "429 rate_limit_error: You've reached your usage limit for this account",
  },
  prime: {
    name: "Prime Intellect",
    program: "prime-agent",
    channel: "standalone",
    login: null,
    kind: "acp",
    models: [{ id: "intellect-4", name: "INTELLECT-4" }],
    signedOut: AUTH_REQUIRED,
    limit: "Insufficient credits: add credits to your Prime Intellect account to continue.",
  },
};

/// A harness this table does not know still gets a cell: an ACP adapter named by its id.
function known(harness: string): Known {
  return (
    KNOWN[harness] ?? {
      name: harness,
      program: harness,
      channel: "standalone",
      login: null,
      kind: "acp",
      models: [{ id: "default", name: "default (agent's choice)" }],
      signedOut: AUTH_REQUIRED,
      limit: "You've reached your usage limit for this account",
    }
  );
}

/// The harnesses the table knows (the matrix adds every harness the picker lists).
export const JOURNEY_HARNESSES = Object.keys(KNOWN);

/// `HARNESS:STATE`, or undefined for anything else.
export function parseJourneyCell(value: string | null | undefined): JourneyCell | undefined {
  const [harness, state] = (value ?? "").split(":");
  if (!harness || !/^[a-z0-9-]+$/.test(harness)) return undefined;
  if (!(JOURNEY_STATES as readonly string[]).includes(state ?? "")) return undefined;
  return { harness, state: state as JourneyState };
}

/// The cell this page runs, when it runs one: the global a driver sets, else `?journey=`.
export function journeyCell(): JourneyCell | undefined {
  const set = (globalThis as { cmuxAcpmuxMockJourney?: unknown }).cmuxAcpmuxMockJourney;
  if (set && typeof set === "object")
    return parseJourneyCell(`${(set as JourneyCell).harness}:${(set as JourneyCell).state}`);
  if (typeof location === "undefined") return undefined;
  return parseJourneyCell(new URLSearchParams(location.search).get("journey"));
}

const installed = (cell: JourneyCell) => cell.state !== "not-installed";

/// `_acpmux/harnesses` as the mock serves it: the cell's harness when it is installed, else none.
export function journeyHarnesses(
  cell: JourneyCell,
): { id: string; name: string; models: { id: string; name: string }[] }[] {
  if (!installed(cell)) return [];
  const entry = known(cell.harness);
  return [{ id: cell.harness, name: entry.name, models: entry.models }];
}

const VERSIONS: Record<string, string> = { claude: "2.1.301", codex: "0.71.0", gemini: "0.24.0", opencode: "1.3.2" };

/// `_acpmux/harness/health` rows (harness_health/mod.rs HarnessHealth, camelCase).
export function journeyHealth(cell: JourneyCell, now = Date.now()): Record<string, unknown>[] {
  if (!installed(cell)) return [];
  const entry = known(cell.harness);
  const signedOut = cell.state === "signed-out";
  return [
    {
      id: cell.harness,
      program: entry.program,
      path: `/usr/local/bin/${entry.program}`,
      channel: entry.channel,
      package: entry.package ?? null,
      version: VERSIONS[cell.harness] ?? "1.0.0",
      latest: VERSIONS[cell.harness] ?? "1.0.0",
      latestCheckedAt: now,
      outdated: false,
      auth: signedOut ? "signedOut" : "signedIn",
      authDetail: signedOut
        ? cell.harness === "codex"
          ? "`codex login status`: not logged in"
          : cell.harness === "claude"
            ? "Not logged in · Please run /login"
            : null
        : cell.harness === "codex"
          ? "`codex login status` passed"
          : null,
      login: entry.login,
      update: null,
      problem: null,
      checkedAt: now,
      autoUpdate: false,
      lastAutoUpdate: null,
    },
  ];
}

/// Settings > Agents' harness rows (pages/settings/ops.ts HarnessRow), as the app maps the daemon's.
export function journeySettingsHarnesses(cell: JourneyCell): Record<string, unknown>[] {
  return journeyHealth(cell).map((row) => ({
    id: row.id,
    name: null,
    kind: known(cell.harness).kind,
    source: "path",
    problem: null,
    version: row.version,
    latest: row.latest,
    outdated: false,
    auth: row.auth,
    update: null,
    checkedAt: row.checkedAt,
  }));
}

/// Why `session/new` on `harness` fails in this cell (config.rs), or undefined when it starts.
export function journeyStartError(cell: JourneyCell, harness: string): { message: string; code: number } | undefined {
  if (harness === cell.harness && installed(cell)) return undefined;
  const profiles = installed(cell) ? cell.harness : "";
  return {
    message: `unknown harness ${JSON.stringify(harness)}; families: ${profiles}; profiles: ${profiles}; presets: none`,
    code: -32602,
  };
}

/// A turn on `harness` in this cell: undefined runs the scripted reply; else the JSON-RPC error
/// `session/prompt` answers with and the turn_error/turn_result fields acpmux logs (hub/turns.rs).
export function journeyTurnFailure(
  cell: JourneyCell,
  harness: string,
): { message: string; code: number; data?: { errorKind: string; recovery: string } } | undefined {
  if (harness !== cell.harness) return undefined;
  const entry = known(cell.harness);
  if (cell.state === "signed-out") {
    // recovery.rs types only the sign-in failures claude_auth.rs recognizes.
    const typed = /not logged in|please run \/login|invalid api key/i.test(entry.signedOut);
    return {
      message: entry.signedOut,
      code: -32000,
      ...(typed
        ? {
            data: {
              errorKind: "auth.signed_out",
              recovery:
                "The agent is not signed in. Sign in with its login command (`cmux harness login <harness>`, or the harness's own login in a terminal on this machine), then send the message again.",
            },
          }
        : {}),
    };
  }
  if (cell.state === "expired") return { message: entry.limit, code: -32603 };
  return undefined;
}
