// Settings > MCP Servers, under cmux's own: a "Claude Code" and a "Codex" group with the MCP servers
// the person gave those agents in their own files (Labs `labs.agentCustomization`; the app runs the
// bundled `cmux agent-config mcp --json`, cmux-agent-customize `mcp.rs`). Each row says where it is
// set and what it runs, with its switch and Remove; Add Server… writes a new one. Nothing changes
// without a click, and no row holds a secret (env and header values stay in the agents' files).
//
// Leo, 2026-11-19: "when I say Claude Code, when I say Codex [...] I need you guys to be, like,
// doing the thing."
import { useCallback, useEffect, useId, useState } from "react";
import { Button } from "../../../ui/Button";
import { Input } from "../../../ui/Input";
import { Switch } from "../../../ui/Switch";
import { useStore } from "../context";
import { Select } from "../editors/Select";
import type { AgentMcpRun, AgentMcpServer, AgentMcpState } from "../ops";
import { t } from "../strings";

type Agent = AgentMcpServer["agent"];
type Gesture = Exclude<AgentMcpRun, { action: "refresh" | "pickFolder" | "add" }>["action"];

const AGENTS: Agent[] = ["claude", "codex"];

/** The scopes an add may name, per agent (Codex has no `local`). */
const ADD_SCOPES: Record<Agent, ("user" | "local" | "project")[]> = {
  claude: ["user", "local", "project"],
  codex: ["user", "project"],
};

export const rowKey = (row: Pick<AgentMcpServer, "agent" | "scope" | "name">) =>
  `${row.agent}:${row.scope}:${row.name}`;

/** What it runs: the URL, or the command and its (masked) arguments. */
export function runs(row: AgentMcpServer): string {
  if (row.url) return row.url;
  return [row.command ?? "", ...row.args].join(" ").trim();
}

/** Splits `KEY=VALUE` lines (one per line), dropping blanks. */
function lines(text: string): string[] {
  return text
    .split("\n")
    .map((line) => line.trim())
    .filter((line) => line.includes("="));
}

/** Splits a command line on spaces, keeping "quoted words" whole. */
export function words(text: string): string[] {
  return (text.match(/"[^"]*"|'[^']*'|\S+/g) ?? []).map((word) => word.replace(/^(["'])(.*)\1$/, "$2"));
}

function Row({
  row,
  busy,
  error,
  onRun,
}: {
  row: AgentMcpServer;
  busy: boolean;
  error: string | null;
  onRun: (action: Gesture) => void;
}) {
  const titleId = useId();
  const [confirming, setConfirming] = useState(false);
  const details = [
    row.plugin
      ? t("settingsWindow.agentMcp.scope.plugin", row.plugin)
      : t(`settingsWindow.agentMcp.scope.${row.scope}`),
    row.transport,
    row.env.length > 0 ? t("settingsWindow.agentMcp.env", row.env.join(", ")) : null,
  ].filter((part): part is string => !!part);
  return (
    <div
      className="row accounts-row"
      data-agent-mcp={rowKey(row)}
      data-agent-mcp-enabled={row.enabled ? "true" : "false"}
    >
      <div className="row-main">
        <div className="row-label">
          <div className="row-title selectable" id={titleId}>
            {row.name}
          </div>
          <div className="row-help selectable">{details.join(" · ")}</div>
          <div className="row-help selectable font-mono" title={row.file}>
            {runs(row)}
          </div>
          {row.approval === "pending" && (
            <div className="row-help" data-agent-mcp-pending="">
              {t("settingsWindow.agentMcp.pending")}
            </div>
          )}
          {row.shadowed && (
            <div className="row-help" data-agent-mcp-shadowed="">
              {t("settingsWindow.agentMcp.shadowed")}
            </div>
          )}
          {error !== null && (
            <div className="row-error selectable" role="alert" data-agent-mcp-error="">
              {error || t("settingsWindow.mcpServers.error.notFinished")}
            </div>
          )}
        </div>
        <span className="row-control keys-control">
          {row.removable && !confirming && (
            <Button
              danger
              variant="ghost"
              className="button"
              data-agent-mcp-action="remove"
              aria-label={t("settingsWindow.mcpServers.removeServer", row.name)}
              disabled={busy}
              onClick={() => setConfirming(true)}
            >
              {t("settingsWindow.mcpServers.remove")}
            </Button>
          )}
          <Switch
            data-agent-mcp-action="toggle"
            aria-labelledby={titleId}
            checked={row.enabled}
            disabled={busy}
            onCheckedChange={(on) => onRun(on ? "enable" : "disable")}
          />
        </span>
      </div>
      {confirming && (
        // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
        <div
          className="accounts-form"
          data-agent-mcp-confirm=""
          // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- a fieldset would draw its own border and inset in the settings form
          role="group"
          aria-label={t("settingsWindow.mcpServers.removeTitle", row.name)}
        >
          <div className="row-title">{t("settingsWindow.mcpServers.removeTitle", row.name)}</div>
          <div className="row-help selectable">{t("settingsWindow.agentMcp.removeBody", row.file)}</div>
          <div className="accounts-buttons">
            <Button
              danger
              variant="ghost"
              className="button"
              data-agent-mcp-action="confirmRemove"
              disabled={busy}
              onClick={() => {
                setConfirming(false);
                onRun("remove");
              }}
            >
              {t("settingsWindow.mcpServers.remove")}
            </Button>
            <Button className="button" data-agent-mcp-action="cancel" onClick={() => setConfirming(false)}>
              {t("settingsWindow.mcpServers.cancel")}
            </Button>
          </div>
        </div>
      )}
    </div>
  );
}

function AddForm({
  agent,
  busy,
  onAdd,
  onCancel,
}: {
  agent: Agent;
  busy: boolean;
  onAdd: (run: Extract<AgentMcpRun, { action: "add" }>) => void;
  onCancel: () => void;
}) {
  const [name, setName] = useState("");
  const [target, setTarget] = useState("");
  const [env, setEnv] = useState("");
  const [scope, setScope] = useState<"user" | "local" | "project">("user");
  const scopeId = useId();
  const envId = useId();
  const url = /^https?:\/\//.test(target.trim());
  const valid = /^[A-Za-z0-9_-]{1,64}$/.test(name) && target.trim().length > 0;
  const submit = () => {
    if (!valid) return;
    const [command, ...args] = words(target.trim());
    onAdd({
      action: "add",
      agent,
      name,
      scope,
      ...(url ? { url: target.trim(), headers: lines(env) } : { command: command!, args, env: lines(env) }),
    });
  };
  return (
    // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
    <div
      className="accounts-form"
      data-agent-mcp-add={agent}
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- a fieldset would draw its own border and inset in the settings form
      role="group"
      aria-label={t("settingsWindow.agentMcp.add")}
    >
      <Input
        className="field"
        aria-label={t("settingsWindow.agentMcp.name")}
        placeholder={t("settingsWindow.agentMcp.name")}
        spellCheck={false}
        autoComplete="off"
        value={name}
        data-agent-mcp-field="name"
        onChange={(event) => setName(event.currentTarget.value)}
      />
      <Input
        className="field font-mono"
        aria-label={t("settingsWindow.agentMcp.target")}
        placeholder={t("settingsWindow.agentMcp.target")}
        spellCheck={false}
        autoComplete="off"
        value={target}
        data-agent-mcp-field="target"
        onChange={(event) => setTarget(event.currentTarget.value)}
      />
      <div className="row-main">
        <div className="row-label">
          <div className="row-title" id={scopeId}>
            {t("settingsWindow.agentMcp.scopeLabel")}
          </div>
        </div>
        <Select value={scope} disabled={busy} labelId={scopeId} onChange={(value) => setScope(value as typeof scope)}>
          {ADD_SCOPES[agent].map((option) => (
            <option key={option} value={option}>
              {t(`settingsWindow.agentMcp.scope.${option}`)}
            </option>
          ))}
        </Select>
      </div>
      <label className="row-help" htmlFor={envId}>
        {t(url ? "settingsWindow.agentMcp.headersLabel" : "settingsWindow.agentMcp.envLabel")}
      </label>
      <textarea
        id={envId}
        aria-label={t(url ? "settingsWindow.agentMcp.headersLabel" : "settingsWindow.agentMcp.envLabel")}
        className="field font-mono"
        rows={2}
        spellCheck={false}
        autoComplete="off"
        value={env}
        data-agent-mcp-field="env"
        onChange={(event) => setEnv(event.currentTarget.value)}
      />
      <div className="accounts-buttons">
        <Button className="button" data-agent-mcp-action="save" disabled={busy || !valid} onClick={submit}>
          {t("settingsWindow.agentMcp.save")}
        </Button>
        <Button className="button" data-agent-mcp-action="cancelAdd" onClick={onCancel}>
          {t("settingsWindow.mcpServers.cancel")}
        </Button>
      </div>
    </div>
  );
}

function Group({
  agent,
  state,
  busy,
  onRun,
}: {
  agent: Agent;
  state: AgentMcpState;
  busy: boolean;
  onRun: (run: AgentMcpRun) => Promise<void>;
}) {
  const [adding, setAdding] = useState(false);
  const rows = state.servers.filter((row) => row.agent === agent);
  const problems = (state.problems ?? []).filter((problem) => problem.agent === agent);
  return (
    <section className="group" data-card="agentMcp" data-agent-mcp-group={agent}>
      <div className="group-title">{t(`settingsWindow.agentMcp.${agent}`)}</div>
      <div className="row-help">{t(`settingsWindow.agentMcp.help.${agent}`)}</div>
      {problems.map((problem) => (
        <div className="row-error selectable" key={problem.why} data-agent-mcp-file-problem="">
          {problem.why}
        </div>
      ))}
      {rows.length === 0 && (
        <div className="row-help" data-agent-mcp-empty={agent}>
          {t("settingsWindow.agentMcp.empty")}
        </div>
      )}
      {rows.length > 0 && (
        <div className="rows">
          {rows.map((row) => (
            <Row
              key={rowKey(row)}
              row={row}
              busy={busy}
              error={state.error?.key === rowKey(row) ? state.error.why : null}
              onRun={(action) => void onRun({ action, agent: row.agent, name: row.name, scope: row.scope })}
            />
          ))}
        </div>
      )}
      {state.error &&
        !rows.some((row) => rowKey(row) === state.error!.key) &&
        state.error.key.startsWith(`${agent}:`) && (
          <div className="row-error selectable" role="alert" data-agent-mcp-error="">
            {state.error.why || t("settingsWindow.mcpServers.error.notFinished")}
          </div>
        )}
      {adding ? (
        <AddForm
          agent={agent}
          busy={busy}
          onCancel={() => setAdding(false)}
          onAdd={(run) => void onRun(run).then(() => setAdding(false))}
        />
      ) : (
        <div className="accounts-header">
          <Button className="button" data-agent-mcp-action="add" disabled={busy} onClick={() => setAdding(true)}>
            {t("settingsWindow.agentMcp.add")}
          </Button>
        </div>
      )}
    </section>
  );
}

/** The Claude Code and Codex groups; nothing at all while the Labs switch is off. */
export function AgentMcpServers() {
  const store = useStore();
  const [state, setState] = useState<AgentMcpState | null>(null);
  const [busy, setBusy] = useState(false);
  useEffect(() => {
    void store.runAgentMcp({ action: "refresh" }).then(setState);
  }, [store]);
  const run = useCallback(
    (gesture: AgentMcpRun) => {
      setBusy(true);
      return store
        .runAgentMcp(gesture)
        .then(setState)
        .finally(() => setBusy(false));
    },
    [store],
  );
  if (!state?.enabled) return null;
  return (
    <div data-agent-mcp="" data-agent-mcp-list-ms={state.listMs ?? undefined}>
      <div className="accounts-header" data-agent-mcp-folder="">
        <span className="row-help selectable font-mono">
          {t("settingsWindow.agentMcp.folder", state.project ?? "")}
        </span>
        <Button
          className="button"
          data-agent-mcp-action="pickFolder"
          disabled={busy}
          onClick={() => void run({ action: "pickFolder" })}
        >
          {t("settingsWindow.agentMcp.chooseFolder")}
        </Button>
        <Button
          className="button"
          data-agent-mcp-action="refresh"
          disabled={busy || (state.loading ?? false)}
          onClick={() => void run({ action: "refresh" })}
        >
          {t("settingsWindow.mcpServers.refresh")}
        </Button>
      </div>
      {state.problem && (
        <div className="row-error" data-agent-mcp-problem={state.problem}>
          {t(`settingsWindow.agentMcp.problem.${state.problem}`)}
        </div>
      )}
      {AGENTS.map((agent) => (
        <Group key={agent} agent={agent} state={state} busy={busy} onRun={run} />
      ))}
    </div>
  );
}
