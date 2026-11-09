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
    iconSpec: { kind: "monogram", text: "AA", hue: 212, source: "default" },
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

/** Settings > Agents > Add > Endpoint's host calls (`cmux.chief.backend.add|doctor`): what the
 * endpoint lists for `*` and the hello turn's answer. */
export type MockEndpoint = {
  served: string[];
  doctor: { ok: boolean; steps: { name: string; ok: boolean; detail?: string; fix?: string }[] };
  /** Set by a test: the add (or the check) answers only when this settles. */
  holdAdd?: Promise<void>;
  holdDoctor?: Promise<void>;
  holdRemove?: Promise<void>;
  holdList?: Promise<void>;
  /** The add answers this error before writing anything (a `*` read that failed). */
  addFails?: string;
  /** The add writes the endpoint, then answers this error (an add that timed out after writing). */
  addThenFail?: string;
  /** Terminal harness ids acpmux lists (kind "terminal"; the Chief picker leaves them out). */
  terminals?: string[];
};

export class MockAgents {
  state: AgentsState = { status: "ready", manages: true, harnesses: HARNESSES, doctor: {} };
  endpoint: MockEndpoint = {
    served: ["model-large", "model-medium", "model-small"],
    doctor: { ok: true, steps: [{ name: "prompt", ok: true }] },
  };
  /** Each endpoint harness added and its models, as acpmux lists them. */
  private endpoints = new Map<string, { name: string; kind: string; models: string[] }>();
  registry: AgentRegistryAgent[] = REGISTRY;
  readonly listeners = new Set<(state: AgentsState) => void>();
  private backups = 0;

  /** Every key the host stored, by harness id (what `secret/set` wrote), for tests. */
  readonly keys = new Map<string, string>();

  /** `cmux.chief.backend.add` for an endpoint, as the host and acpmux run it: the page's id (else
   * one from the name), refused when acpmux has it unless `replace` names it, the key stored only
   * when sent, `*` the endpoint's list. */
  addEndpoint(params: Record<string, unknown>): { id: string } {
    const name = String(params.name ?? "").trim();
    const kind = String(params.kind ?? "");
    if (!name) throw new ProtocolError("cmux.page.invalid_params", "name is required");
    const slug = (text: string) =>
      text
        .toLowerCase()
        .replace(/[^a-z0-9]+/g, "-")
        .replace(/^-+|-+$/g, "")
        .slice(0, 40) || "my-backend";
    const id = slug(String(params.id ?? "") || name);
    const replace = params.replace === id;
    const apiKey = String(params.apiKey ?? "");
    const models: string[] = [];
    for (const word of String(params.model ?? "").split(",")) {
      for (const model of word.trim() === "*" ? this.endpoint.served : [word.trim()])
        if (model && !models.includes(model)) models.push(model);
    }
    if (models.length === 0) throw new ProtocolError("cmux.page.invalid_params", "model is required");
    if (!replace && (this.state.harnesses.some((row) => row.id === id) || this.endpoints.has(id)))
      throw new ProtocolError("cmux.agents.exists", `${id} already has a profile`);
    if (apiKey) this.keys.set(id, apiKey);
    this.endpoints.set(id, { name, kind, models });
    const row: AgentHarnessRow = {
      id,
      name,
      kind: kind === "anthropic-endpoint" ? "claude-stdio" : "acp",
      source: "user",
      removable: true,
      default: false,
    };
    this.state = { ...this.state, harnesses: [...this.state.harnesses.filter((entry) => entry.id !== id), row] };
    for (const listener of this.listeners) listener(this.state);
    return { id };
  }

  /** The endpoint harnesses for `cmux.chief.backend.list`'s `_acpmux/harnesses` part. */
  endpointHarnesses(): Record<string, { displayName: string; models: string[] }> {
    // As acpmux serializes a profile's declared models: each as its id string.
    const out: Record<string, { displayName: string; models: string[] }> = {};
    for (const [id, entry] of this.endpoints)
      out[id] = {
        displayName: entry.name,
        models: entry.models.map((model) => (entry.kind === "openai-endpoint" ? `byo/${model}` : model)),
      };
    return out;
  }

  /** The terminal harnesses for the same list (kind "terminal"). */
  terminalHarnesses(): Record<string, { displayName: string; kind: string; models: string[] }> {
    return Object.fromEntries(
      (this.endpoint.terminals ?? []).map((id) => [id, { displayName: id, kind: "terminal", models: [] }]),
    );
  }

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
        // An endpoint the Endpoint form added leaves the backend list too.
        this.endpoints.delete(gesture.id);
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
      case "symbol":
        // The host's template image of the symbol (a 1x1 PNG here).
        return {
          src: "data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4nGNgYGD4DwABBAEAwS2OUAAAAABJRU5ErkJggg==",
        };
      case "icon": {
        // acpmux's resolution, as far as Settings shows it: the value, an image, or Automatic.
        const iconSpec = gesture.clear
          ? { kind: "monogram", text: "AA", hue: 212, source: "default" }
          : gesture.data
            ? {
                kind: "image",
                mime: gesture.ext === "svg" ? "image/svg+xml" : "image/png",
                data: gesture.data,
                source: "profile",
              }
            : /^\p{Extended_Pictographic}/u.test(gesture.icon ?? "")
              ? { kind: "emoji", text: gesture.icon, source: "profile" }
              : { kind: "symbol", name: gesture.icon, text: "AA", hue: 212, source: "profile" };
        const icon = gesture.clear ? undefined : gesture.data ? `${gesture.id}.${gesture.ext ?? "png"}` : gesture.icon;
        this.state = {
          ...this.state,
          harnesses: this.state.harnesses.map((row) => (row.id === gesture.id ? { ...row, icon, iconSpec } : row)),
        };
        return { id: gesture.id, icon };
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
