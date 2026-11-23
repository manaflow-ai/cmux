// l10n-allow-file: mock fixtures (sample paths, keys and values), not shipped UI.
// Settings > Agents > Claude Code & Codex as `cmux --json agent-config settings get` answers it,
// for the mock provider, tests and the gallery: Claude Code with a managed file that does not
// exist, a user file holding a masked API key, a project file overriding the user's model and a
// local file; Codex with its user config.toml, a missing project file and one profile. `set` and
// `unset` change it in memory as the CLI would (one scope, the writable scopes only).
import { AGENT_CUSTOMIZATION_LAB } from "./agentConfig";
import { rowsByKey, schema, type SchemaRow } from "./schema";
import type { AgentConfigAgent, AgentConfigAnswer, AgentConfigEntry, AgentConfigRun, AgentConfigState } from "./ops";

/** What the CLI prints for a secret (`masked: true`). */
export const MASK = "••••••";
/** The raw secret the mock's user file holds; the page must never show it. */
export const MOCK_SECRET = "sk-ant-mock-0123456789";

const HOME = "/Users/you";
const PROJECT = "/Users/you/code/app";

const claudeFiles = () => [
  {
    scope: "managed",
    label: "Managed",
    path: "/Library/Application Support/ClaudeCode/managed-settings.json",
    exists: false,
    writable: false,
    keys: 0,
    error: null,
  },
  {
    scope: "user",
    label: "User",
    path: `${HOME}/.claude/settings.json`,
    exists: true,
    writable: true,
    keys: 5,
    error: null,
  },
  {
    scope: "project",
    label: "Project",
    path: `${PROJECT}/.claude/settings.json`,
    exists: true,
    writable: true,
    keys: 2,
    error: null,
  },
  {
    scope: "local",
    label: "Local",
    path: `${PROJECT}/.claude/settings.local.json`,
    exists: true,
    writable: true,
    keys: 1,
    error: null,
  },
];

const codexFiles = () => [
  {
    scope: "user",
    label: "User",
    path: `${HOME}/.codex/config.toml`,
    exists: true,
    writable: true,
    keys: 6,
    error: null,
  },
  {
    scope: "project",
    label: "Project",
    path: `${PROJECT}/.codex/config.toml`,
    exists: false,
    writable: true,
    keys: 0,
    error: null,
  },
];

const entry = (
  key: string,
  display: string,
  scope: string,
  path: string,
  extra: Partial<AgentConfigEntry> = {},
): AgentConfigEntry => ({ key, display, scope, path, overridden: [], masked: false, curated: false, ...extra });

/** Claude Code's settings as `get --agent claude` answers them. */
export function mockClaudeConfig(): AgentConfigState {
  const files = claudeFiles();
  const [, user, project, local] = files;
  return {
    agent: "claude",
    files,
    entries: [
      entry("model", "sonnet", "project", project.path, {
        overridden: [{ scope: "user", display: "opus" }],
        curated: true,
      }),
      entry("permissions.defaultMode", "plan", "local", local.path, { curated: true }),
      entry("env.ANTHROPIC_API_KEY", MASK, "user", user.path, { masked: true }),
      entry("permissions.allow", "4 items", "user", user.path),
      entry("hooks.PostToolUse", "2 items", "user", user.path),
      entry("statusLine.command", "~/.claude/statusline.sh", "user", user.path),
      entry("enabledPlugins.formatter", "true", "project", project.path),
    ],
    curated: [
      {
        key: "model",
        title: "Model",
        kind: "text",
        choices: ["default", "sonnet", "opus", "haiku"],
        value: "sonnet",
        scope: "project",
        writableScopes: ["user", "project", "local"],
      },
      {
        key: "permissions.defaultMode",
        title: "Permission mode",
        kind: "choice",
        choices: ["default", "acceptEdits", "plan", "bypassPermissions"],
        value: "plan",
        scope: "local",
        writableScopes: ["user", "project", "local"],
      },
      {
        key: "cleanupPeriodDays",
        title: "Keep transcripts (days)",
        kind: "text",
        choices: ["30", "90"],
        value: null,
        scope: null,
        writableScopes: ["user", "project", "local"],
      },
    ],
    profiles: [],
    notes: ["Claude Code reads managed, then local, project and user settings; the first that sets a key wins."],
    keysOnDisk: 8,
    keysShown: 7,
  };
}

/** Codex's settings as `get --agent codex` answers them. */
export function mockCodexConfig(): AgentConfigState {
  const files = codexFiles();
  const [user] = files;
  return {
    agent: "codex",
    files,
    entries: [
      entry("model", "gpt-5-codex", "user", user.path, { curated: true }),
      entry("model_reasoning_effort", "high", "user", user.path, { curated: true }),
      entry("approval_policy", "on-request", "user", user.path, { curated: true }),
      entry("sandbox_mode", "workspace-write", "user", user.path, { curated: true }),
      entry("shell_environment_policy.set.OPENAI_API_KEY", MASK, "user", user.path, { masked: true }),
      entry("mcp_servers.linear.url", "https://mcp.linear.app/sse", "user", user.path),
    ],
    curated: [
      {
        key: "model",
        title: "Model",
        kind: "text",
        choices: ["gpt-5-codex", "gpt-5"],
        value: "gpt-5-codex",
        scope: "user",
        writableScopes: ["user", "project", "profile:fast"],
      },
      {
        key: "model_reasoning_effort",
        title: "Reasoning effort",
        kind: "choice",
        choices: ["minimal", "low", "medium", "high"],
        value: "high",
        scope: "user",
        writableScopes: ["user", "project", "profile:fast"],
      },
      {
        key: "approval_policy",
        title: "Approval policy",
        kind: "choice",
        choices: ["untrusted", "on-failure", "on-request", "never"],
        value: "on-request",
        scope: "user",
        writableScopes: ["user", "project", "profile:fast"],
      },
      {
        key: "sandbox_mode",
        title: "Sandbox",
        kind: "choice",
        choices: ["read-only", "workspace-write", "danger-full-access"],
        value: "workspace-write",
        scope: "user",
        writableScopes: ["user", "project", "profile:fast"],
      },
    ],
    profiles: [{ name: "fast", path: `${HOME}/.codex/fast.config.toml`, keys: 2 }],
    notes: ["Codex picks a profile per run (--profile NAME); there is no saved active profile."],
    keysOnDisk: 6,
    keysShown: 6,
  };
}

/** Both agents, fresh. */
export const mockAgentConfig = (): Record<AgentConfigAgent, AgentConfigState> => ({
  claude: mockClaudeConfig(),
  codex: mockCodexConfig(),
});

/** Tests only: the Labs row `labs.agentCustomization` in the page's schema when the checked-in
 * export (settings-schema.json, regenerated on a Mac) does not have it yet, shaped like the other
 * Labs toggles; a no-op once the export lists it. */
export function ensureAgentCustomizationLabRow(): void {
  if (rowsByKey.has(AGENT_CUSTOMIZATION_LAB)) return;
  const like = schema.rows.find(
    (row) => row.section === "advanced" && row.kind === "toggle" && row.key.startsWith("labs."),
  );
  if (!like) throw new Error("no Labs toggle to copy");
  const row: SchemaRow = {
    ...structuredClone(like),
    key: AGENT_CUSTOMIZATION_LAB,
    path: ["labs", "agentCustomization"],
    default: false,
    title: { key: "settings.labs.agentCustomization", text: "Claude Code and Codex Customization" },
    help: {
      key: "settings.labs.agentCustomization.help",
      text: "Shows and edits Claude Code's and Codex's own settings.",
    },
  };
  schema.rows.push(row);
  (rowsByKey as Map<string, SchemaRow>).set(row.key, row);
}

const refusal = (message: string) => ({ code: "agent_config.invalid", message });

/** The file a scope writes (`profile:NAME` writes that profile's file). */
function fileFor(state: AgentConfigState, scope: string): string | null {
  if (scope.startsWith("profile:")) return state.profiles?.find((p) => `profile:${p.name}` === scope)?.path ?? null;
  return state.files.find((file) => file.scope === scope)?.path ?? null;
}

/** One CLI verb on `state`, as `cmux agent-config settings` runs it: the next state (unchanged on
 * a refusal or a read) and the answer the host passes on. */
export function runAgentConfigMock(
  state: AgentConfigState,
  run: AgentConfigRun,
): { state: AgentConfigState; answer: AgentConfigAnswer } {
  if (run.verb === "get") return { state, answer: structuredClone(state) };
  if (run.verb === "open") {
    const file = state.files.find((candidate) => candidate.path === run.path);
    if (!file) return { state, answer: refusal("that file is not one of this agent's settings files") };
    if (!file.exists) return { state, answer: refusal("the file does not exist yet") };
    return { state, answer: { ok: true } };
  }
  const row = state.curated.find((candidate) => candidate.key === run.key);
  if (!row) return { state, answer: refusal(`${run.key ?? ""} is not a setting cmux edits`) };
  const scope = run.scope ?? "user";
  if (!row.writableScopes.includes(scope)) return { state, answer: refusal(`cmux cannot write the ${scope} scope`) };
  const path = fileFor(state, scope);
  if (!path) return { state, answer: refusal(`there is no ${scope} file`) };
  const next = structuredClone(state);
  const curated = next.curated.find((candidate) => candidate.key === row.key)!;
  const others = next.entries.filter((candidate) => candidate.key !== row.key);
  if (run.verb === "set") {
    const value = run.value ?? "";
    if (row.kind === "choice" && !row.choices.includes(value))
      return { state, answer: refusal(`${value} is not one of ${row.choices.join(", ")}`) };
    curated.value = value;
    curated.scope = scope;
    next.entries = [entry(row.key, value, scope, path, { curated: true }), ...others];
    next.files = next.files.map((file) => (file.path === path ? { ...file, exists: true } : file));
  } else {
    if (curated.scope === scope) {
      curated.value = null;
      curated.scope = null;
      next.entries = others;
    }
  }
  next.keysShown = next.entries.length;
  next.keysOnDisk = Math.max(next.keysOnDisk, next.entries.length);
  return {
    state: next,
    answer: { ok: true, agent: next.agent, key: row.key, scope, path, backup: `${path}.cmux-bak` },
  };
}
