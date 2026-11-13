// l10n-allow-file: fixture data (sample addresses, machine and team names), not shipped UI.
// Fixture states of Settings > Models (ModelsCard.tsx) as the app's `cmux.settings.models.state`
// answers them (cmux-tui/docs/model-connections.md), and the mock host's answer to the card's gestures.
import { isClaudeToken } from "../../agent-session/shared/claudeSetupToken";
import type { ModelConnection, ModelsRun, ModelsState } from "./ops";

const codexLogin: ModelConnection = {
  id: "codex-login",
  kind: "codex-login",
  provider: "openai",
  families: ["codex"],
  label: "ChatGPT (Codex CLI login)",
  email: "alex@example.com",
  plan: "pro",
  signedIn: true,
  enabled: true,
  defaultFor: ["codex"],
  servesCloud: false,
};

const claudeLogin: ModelConnection = {
  id: "claude-login",
  kind: "claude-login",
  provider: "anthropic",
  families: ["claude"],
  label: "Claude Code login",
  email: "alex@example.com",
  plan: "max",
  signedIn: true,
  enabled: true,
  defaultFor: ["claude"],
  servesCloud: false,
};

const chatgptPlan: ModelConnection = {
  id: "chatgpt",
  kind: "chatgpt-plan",
  provider: "openai",
  families: ["codex"],
  label: "ChatGPT plan (alex@work.example.com)",
  email: "alex@work.example.com",
  plan: "plus",
  signedIn: true,
  enabled: true,
  defaultFor: [],
  servesCloud: true,
};

const claudeToken: ModelConnection = {
  id: "claude-token",
  kind: "claude-token",
  provider: "anthropic",
  families: ["claude"],
  label: "Claude Code token",
  email: null,
  plan: null,
  signedIn: true,
  enabled: true,
  defaultFor: [],
  servesCloud: true,
};

const openrouterKey: ModelConnection = {
  id: "openrouter-key",
  kind: "api-key",
  provider: "openrouter",
  families: ["claude", "codex"],
  label: "OpenRouter API key",
  email: null,
  plan: null,
  signedIn: true,
  enabled: false,
  defaultFor: [],
  // Only Anthropic and OpenAI keys reach Cloud chats (acpmux connections.rs `serves_cloud`).
  servesCloud: false,
};

const empty: ModelsState = {
  personal: { connections: [], spread: true, available: true },
  organization: { team: null, canEdit: false, keys: [] },
  members: null,
  chatgpt: { attempt: null, error: null },
};

const macLogins: ModelsState = {
  personal: {
    connections: [codexLogin, claudeLogin, chatgptPlan, claudeToken, openrouterKey],
    spread: true,
    available: true,
  },
  organization: {
    team: { id: "team-acme", name: "Acme" },
    canEdit: true,
    keys: [
      { agent: "claude", set: true, last4: "abcd" },
      { agent: "codex", set: false, last4: null },
    ],
  },
  members: { ownConnections: true, chooseRunout: false, canEdit: true },
  chatgpt: { attempt: null, error: null },
};

export const mockModels = {
  empty,
  macLogins,
  chatgptPending: { ...macLogins, chatgpt: { attempt: "attempt-1", error: null } },
  chatgptError: { ...macLogins, chatgpt: { attempt: null, error: "no_plan_scope" } },
  member: {
    ...macLogins,
    organization: { ...macLogins.organization, canEdit: false, keys: [{ agent: "claude", set: true, last4: null }] },
    members: { ownConnections: true, chooseRunout: false, canEdit: false },
  },
} satisfies Record<string, ModelsState>;

/** The mock host's answer to one gesture, like the app's: refusals throw with the host's text. */
export function runMockModels(state: ModelsState, run: ModelsRun): ModelsState {
  const connections = state.personal.connections;
  const personal = (next: Partial<ModelsState["personal"]>): ModelsState => ({
    ...state,
    personal: { ...state.personal, ...next },
  });
  const find = (id: string) => {
    const found = connections.find((connection) => connection.id === id);
    if (!found) throw new Error(`unknown connection ${id}`);
    return found;
  };
  switch (run.action) {
    case "order": {
      for (const id of run.ids) find(id);
      const listed = run.ids.map(find);
      return personal({ connections: [...listed, ...connections.filter((c) => !run.ids.includes(c.id))] });
    }
    case "spread":
      return personal({ spread: run.on });
    case "enable":
      find(run.id);
      return personal({ connections: connections.map((c) => (c.id === run.id ? { ...c, enabled: run.on } : c)) });
    case "remove": {
      const found = find(run.id);
      if (found.kind === "codex-login" || found.kind === "claude-login")
        throw new Error(`${run.id} is the CLI's own login: sign out in the CLI, or turn it off`);
      return personal({ connections: connections.filter((c) => c.id !== run.id) });
    }
    case "connectChatGPT":
      return { ...state, chatgpt: { attempt: "attempt-mock", error: null } };
    case "cancelChatGPT":
      return { ...state, chatgpt: { attempt: null, error: null } };
    case "connectClaude":
      return connections.some((c) => c.kind === "claude-login")
        ? state
        : personal({ connections: [...connections, { ...claudeLogin, defaultFor: [] }] });
    case "claudeSetupToken":
      // The app opens a terminal tab running `claude setup-token`; the state does not change.
      return state;
    case "addClaudeToken": {
      if (!isClaudeToken(run.token)) throw new Error("not a Claude setup token");
      const id = nextId("claude-token", connections);
      // The token itself never lands in the state: the app keeps it in the Keychain.
      return personal({
        connections: [...connections, { ...claudeToken, id, label: run.label?.trim() || "Claude Code token" }],
      });
    }
    case "addKey": {
      if (!run.key.trim()) throw new Error("a key is required");
      const provider = KEY_PROVIDERS[run.provider];
      // The key itself never lands in the state: the app keeps it in the Keychain.
      const added: ModelConnection = {
        id: nextId(`${run.provider}-key`, connections),
        kind: "api-key",
        provider: run.provider,
        families: [...provider.families],
        label: run.label?.trim() || provider.label,
        email: null,
        plan: null,
        signedIn: true,
        enabled: true,
        defaultFor: [],
        servesCloud: run.provider === "anthropic" || run.provider === "openai",
      };
      return personal({ connections: [...connections, added] });
    }
    case "orgKey": {
      if (!state.organization.canEdit) throw new Error("only owners and admins change the team's keys");
      const last4 = run.key ? run.key.slice(-4) : null;
      const others = state.organization.keys.filter((key) => key.agent !== run.agent);
      const keys = [...others, { agent: run.agent, set: run.key !== null, last4 }].sort((a, b) =>
        a.agent.localeCompare(b.agent),
      );
      return { ...state, organization: { ...state.organization, keys } };
    }
    case "members": {
      if (!state.members?.canEdit) throw new Error("only owners and admins change the members policy");
      const { action: _action, ...change } = run;
      return { ...state, members: { ...state.members, ...change } };
    }
  }
}

/** acpmux's API-key providers (connections.rs `PROVIDERS`): the label and families each serves. */
const KEY_PROVIDERS: Record<ModelConnection["provider"], { label: string; families: readonly string[] }> = {
  anthropic: { label: "Anthropic API key", families: ["claude"] },
  openai: { label: "OpenAI API key", families: ["codex"] },
  openrouter: { label: "OpenRouter API key", families: ["claude", "codex"] },
  google: { label: "Google AI API key", families: ["gemini"] },
  xai: { label: "xAI API key", families: ["codex"] },
};

/** acpmux's id for a new route: `base`, then `base-2`, `base-3`, ... (the first one free). */
function nextId(base: string, connections: ModelConnection[]): string {
  const taken = new Set(connections.map((c) => c.id));
  if (!taken.has(base)) return base;
  let number = 2;
  while (taken.has(`${base}-${number}`)) number += 1;
  return `${base}-${number}`;
}
