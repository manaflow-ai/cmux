// Fixture states of Settings > Accounts > Team agent keys (TeamAgentKeysCard.tsx), with the texts the
// app's TeamAgentKeys+Page.swift sends, and the mock host's answer to the card's gestures.
import type { AccountsRun, TeamAgentKeyRow, TeamAgentKeysState } from "./ops";

const labels: TeamAgentKeysState["labels"] = {
  add: "Add Key",
  replace: "Replace",
  remove: "Remove",
  confirmRemove: "Remove this team key? Members' runs on the team's Cloud machines go back to their own keys.",
  cancel: "Cancel",
  save: "Save",
  kind: "Key type",
  secret: "Key",
  placeholder: "Paste the key",
};

const unset = (agent: "claude" | "codex"): TeamAgentKeyRow => ({
  agent,
  name: agent === "codex" ? "Codex" : "Claude",
  set: false,
  status: "Not set",
  detail: null,
  error: null,
  notice: null,
});

const claudeSet: TeamAgentKeyRow = {
  ...unset("claude"),
  set: true,
  status: "Team key set",
  detail: "API key · Ending in …abcd · Updated Nov 7, 2026",
};

const base: TeamAgentKeysState = {
  title: "Team agent keys",
  detail:
    "A team key is used for every member's Claude or Codex runs on this team's Cloud machines, in place of their own keys.",
  note: null,
  signIn: null,
  busy: false,
  canManage: true,
  error: null,
  refresh: "Refresh",
  labels,
  kinds: [
    { id: "api_key", title: "API key" },
    { id: "oauth", title: "Subscription token" },
  ],
  agents: [claudeSet, unset("codex")],
};

export const mockAgentKeys = {
  admin: base,
  member: {
    ...base,
    canManage: false,
    note: "Your team's owners and admins manage these keys.",
    agents: [{ ...claudeSet, detail: "API key · Updated Nov 7, 2026" }, unset("codex")],
  } satisfies TeamAgentKeysState,
  signedOut: {
    ...base,
    canManage: false,
    note: "Sign in to cmux to see your team's agent keys.",
    signIn: "Sign In",
    agents: [],
  } satisfies TeamAgentKeysState,
  personal: {
    ...base,
    canManage: false,
    note: "Your personal team has no one to share keys with. Switch to a team to manage its keys.",
    agents: [],
  } satisfies TeamAgentKeysState,
  conflict: {
    ...base,
    agents: [{ ...claudeSet, error: "Another admin changed this key; try again." }, unset("codex")],
  } satisfies TeamAgentKeysState,
};

/** The mock host's answer to an `agentKey*` gesture: a save sets the row, a removal clears it. */
export function runMockAgentKeys(state: TeamAgentKeysState, run: AccountsRun): TeamAgentKeysState {
  if (!state.canManage) return state;
  const agents = state.agents.map((row): TeamAgentKeyRow => {
    if (row.agent !== run.provider) return { ...row, notice: null, error: null };
    if (run.action === "agentKeySave") {
      const kind = state.kinds.find((option) => option.id === run.name)?.title ?? "API key";
      const hint = (run.secret ?? "").slice(-4);
      return {
        ...row,
        set: true,
        status: "Team key set",
        detail: `${kind} · Ending in …${hint}`,
        error: null,
        notice: "Team key saved.",
      };
    }
    if (run.action === "agentKeyRemove")
      return { ...unset(row.agent), notice: "Team key removed. Members' own keys apply again." };
    return row;
  });
  return { ...state, agents };
}
