// Settings > Agents as the app serves it (cmux.settings.agents.*), for the dev server, the gallery
// and the tests: the same rows, gestures and refusals the host's AgentHarnessCenter answers.
import { ProtocolError } from "../../protocol/errors";
import type { AgentHarnessRow, AgentRegistryAgent, AgentsRun, AgentsState } from "./ops";

const HARNESSES: AgentHarnessRow[] = [
  {
    id: "claude",
    name: "Claude Code",
    kind: "claude-stdio",
    source: "builtIn",
    removable: false,
    default: true,
    family: "claude",
  },
  { id: "codex", name: "Codex", kind: "acp", source: "builtIn", removable: false, default: false, family: "codex" },
  {
    id: "gemini",
    name: "Gemini CLI",
    kind: "acp",
    source: "registry",
    removable: false,
    default: false,
    family: "gemini",
  },
  {
    id: "acme-agent",
    name: "Acme Agent",
    kind: "acp",
    source: "user",
    removable: true,
    default: false,
    probeError: "the model probe timed out after 60 s",
  },
];

const REGISTRY: AgentRegistryAgent[] = [
  {
    id: "goose",
    name: "Goose",
    description: "An open-source agent by Block",
    version: "1.12.0",
    launch: "path",
    installed: true,
  },
  { id: "kimi-cli", name: "Kimi CLI", description: "Moonshot's coding agent", version: "0.42.1", launch: "uvx" },
  { id: "qwen-code", name: "Qwen Code", description: "Alibaba's coding agent", version: "0.6.0", launch: "npx" },
  {
    id: "gemini",
    name: "Gemini CLI",
    description: "Google's coding agent",
    version: "0.21.0",
    launch: "path",
    harnessId: "gemini",
  },
  { id: "auggie", name: "Auggie", description: "Augment Code's agent", version: "0.9.0", launch: "none" },
];

export class MockAgents {
  state: AgentsState = { status: "ready", manages: true, harnesses: HARNESSES, doctor: {} };
  registry: AgentRegistryAgent[] = REGISTRY;
  readonly listeners = new Set<(state: AgentsState) => void>();
  private backups = 0;

  /** One gesture, as the host runs it; the change goes to every subscriber. */
  run(gesture: AgentsRun): unknown {
    if (!this.state.manages && gesture.action !== "refresh")
      throw new ProtocolError("cmux.agents.unsupported", "This acpmux cannot add or remove agents from the app.");
    const answer = this.apply(gesture);
    for (const listener of this.listeners) listener(this.state);
    return answer;
  }

  private apply(gesture: AgentsRun): unknown {
    switch (gesture.action) {
      case "refresh":
        return {};
      case "registry":
        this.state = { ...this.state, registry: { agents: this.registry } };
        return this.state.registry;
      case "add": {
        const id = gesture.registry ?? gesture.id ?? (gesture.command ?? "agent").split("/").pop()!;
        if (this.state.harnesses.some((row) => row.id === id))
          throw new ProtocolError("cmux.agents.exists", `${id} already has a profile.`);
        const row: AgentHarnessRow = {
          id,
          name: gesture.displayName ?? this.registry.find((agent) => agent.id === id)?.name ?? id,
          kind: gesture.protocol ?? "acp",
          source: "user",
          removable: true,
          default: false,
        };
        const registry = this.state.registry && {
          agents: this.state.registry.agents.map((agent) => (agent.id === id ? { ...agent, harnessId: id } : agent)),
        };
        this.state = { ...this.state, harnesses: [...this.state.harnesses, row], registry, removed: undefined };
        return { id, path: `~/.config/cmux/harnesses/${id}.toml`, diagnostics: [] };
      }
      case "remove": {
        const row = this.state.harnesses.find((entry) => entry.id === gesture.id);
        if (!row?.removable)
          throw new ProtocolError("cmux.agents.not_removable", `${gesture.id} is not a profile you can remove.`);
        const backup = `${gesture.id}.toml.${(this.backups += 1)}`;
        this.removedRows.set(backup, row);
        this.state = {
          ...this.state,
          harnesses: this.state.harnesses.filter((entry) => entry.id !== gesture.id),
          removed: { id: row.id, backup },
        };
        return { id: row.id, backup };
      }
      case "restore": {
        const backup = gesture.backup ?? this.state.removed?.backup ?? "";
        const row = this.removedRows.get(backup);
        if (!row) throw new ProtocolError("cmux.agents.not_found", "No such backup.");
        this.removedRows.delete(backup);
        this.state = { ...this.state, harnesses: [...this.state.harnesses, row], removed: undefined };
        return { id: row.id, path: `~/.config/cmux/harnesses/${row.id}.toml` };
      }
      case "doctor": {
        const failing = this.state.harnesses.find((row) => row.id === gesture.id)?.probeError;
        const result = {
          ok: !failing,
          steps: [
            { name: "spawn", status: "pass" as const, detail: "started in 0.3 s" },
            { name: "initialize", status: "pass" as const, detail: "protocol 1" },
            failing
              ? {
                  name: "session/new",
                  status: "fail" as const,
                  detail: failing,
                  fix: "Run the agent once in a terminal to sign in.",
                }
              : { name: "session/new", status: "pass" as const, detail: "2 models" },
            { name: "prompt", status: failing ? ("skip" as const) : ("pass" as const) },
          ],
        };
        this.state = { ...this.state, doctor: { ...this.state.doctor, [gesture.id]: result } };
        return result;
      }
    }
  }

  private readonly removedRows = new Map<string, AgentHarnessRow>();
}
