// Settings > Agents > Claude Code & Codex > Settings: each agent's effective settings as the agent
// itself reads them, with the scope each value comes from, through the bundled `cmux --json
// agent-config settings` (cmux-agent-customize settings.rs). The curated keys edit in place (a
// choice writes on pick, a text on Save, Use Default unsets the scope the value comes from); the
// other keys list under All Settings; each config file has Open File. The CLI masks secrets, so no
// value here is ever a raw secret. Read on mount; every write is the person's click, then read again.
import { useCallback, useEffect, useId, useLayoutEffect, useRef, useState } from "react";
import { Button } from "../../../ui/Button";
import { AGENT_CONFIG_AGENTS, defaultScope, scopeLabel } from "../agentConfig";
import { useStore } from "../context";
import type { AgentConfigAgent, AgentConfigCurated, AgentConfigRun, AgentConfigState } from "../ops";
import { t } from "../strings";

/** One agent's part: its settings once read, or why they are not shown. */
type AgentRead =
  | { phase: "loading" }
  | { phase: "ready"; state: AgentConfigState }
  | { phase: "unavailable" }
  | { phase: "failed"; error: string };

function ScopeBadge({ scope }: { scope: string | null }) {
  return (
    <span className="badge" data-agent-scope={scope ?? "default"}>
      {scope ? scopeLabel(scope) : t("settingsWindow.agentConfig.default")}
    </span>
  );
}

function CuratedRow({
  row,
  busy,
  onRun,
}: {
  row: AgentConfigCurated;
  busy: boolean;
  onRun: (run: Omit<AgentConfigRun, "agent">) => Promise<string | null>;
}) {
  const titleId = useId();
  const [scope, setScope] = useState(() => defaultScope(row.writableScopes));
  const [draft, setDraft] = useState(row.value ?? "");
  const [error, setError] = useState<string | null>(null);
  // A fresh read replaces what the field shows.
  const [seen, setSeen] = useState(row.value);
  if (seen !== row.value) {
    setSeen(row.value);
    setDraft(row.value ?? "");
  }
  const run = (change: Omit<AgentConfigRun, "agent">) => void onRun(change).then(setError);
  const set = (value: string) => run({ verb: "set", key: row.key, value, scope });
  const canUnset = row.value !== null && row.scope !== null && row.writableScopes.includes(row.scope);
  const listId = `${titleId}-choices`;
  return (
    <div className="row" data-agent-setting={row.key}>
      <div className="row-main">
        <div className="row-label">
          <div className="row-title" id={titleId}>
            {row.title}
          </div>
          <div className="row-help selectable font-mono">{row.key}</div>
          {error && (
            <div className="row-error selectable" role="alert" data-agent-error="">
              {error}
            </div>
          )}
        </div>
        <span className="row-control keys-control">
          <ScopeBadge scope={row.scope} />
          {row.kind === "choice" ? (
            <select
              className="field"
              aria-labelledby={titleId}
              data-agent-value=""
              value={row.value ?? ""}
              disabled={busy}
              onChange={(event) => set(event.target.value)}
            >
              {row.value === null && <option value="">{t("settingsWindow.agentConfig.default")}</option>}
              {row.choices.map((choice) => (
                <option key={choice} value={choice}>
                  {choice}
                </option>
              ))}
            </select>
          ) : (
            <>
              <input
                className="field font-mono"
                aria-labelledby={titleId}
                data-agent-value=""
                value={draft}
                placeholder={t("settingsWindow.agentConfig.default")}
                list={row.choices.length > 0 ? listId : undefined}
                spellCheck={false}
                disabled={busy}
                onChange={(event) => setDraft(event.target.value)}
                onKeyDown={(event) => {
                  if (event.key === "Enter" && draft.trim() !== "" && draft !== row.value) set(draft);
                }}
              />
              {row.choices.length > 0 && (
                <datalist id={listId}>
                  {row.choices.map((choice) => (
                    <option key={choice} value={choice} aria-label={choice} />
                  ))}
                </datalist>
              )}
              <Button
                className="button"
                data-agent-action="save"
                aria-describedby={titleId}
                disabled={busy || draft.trim() === "" || draft === row.value}
                onClick={() => set(draft)}
              >
                {t("settingsWindow.agentConfig.save")}
              </Button>
            </>
          )}
          {row.writableScopes.length > 1 && (
            <select
              className="field"
              aria-label={t("settingsWindow.agentConfig.saveIn", row.title)}
              data-agent-scope-picker=""
              value={scope}
              disabled={busy}
              onChange={(event) => setScope(event.target.value)}
            >
              {row.writableScopes.map((option) => (
                <option key={option} value={option}>
                  {scopeLabel(option)}
                </option>
              ))}
            </select>
          )}
          <Button
            variant="ghost"
            className="button"
            data-agent-action="unset"
            aria-describedby={titleId}
            disabled={busy || !canUnset}
            onClick={() => row.scope && run({ verb: "unset", key: row.key, scope: row.scope })}
          >
            {t("settingsWindow.agentConfig.useDefault")}
          </Button>
        </span>
      </div>
    </div>
  );
}

function AllSettings({ state }: { state: AgentConfigState }) {
  const id = useId();
  const [open, setOpen] = useState(false);
  return (
    <>
      <button
        type="button"
        className="more-options"
        aria-expanded={open}
        aria-controls={id}
        data-open={open ? "" : undefined}
        data-agent-action="all"
        onClick={() => setOpen(!open)}
      >
        <span className="more-options-label">{t("settingsWindow.agentConfig.all", state.entries.length)}</span>
      </button>
      {open && (
        <div className="rows" id={id} data-agent-entries="">
          {state.entries.map((entry) => (
            <div className="row" key={entry.key} data-agent-entry={entry.key}>
              <div className="row-main">
                <div className="row-label">
                  <div className="row-title selectable font-mono">{entry.key}</div>
                  {entry.overridden.map((other) => (
                    <div className="row-help selectable" key={other.scope} data-agent-overridden={other.scope}>
                      {t("settingsWindow.agentConfig.alsoSet", scopeLabel(other.scope), other.display)}
                    </div>
                  ))}
                </div>
                <span className="row-control keys-control">
                  <span
                    className="row-help selectable font-mono"
                    data-agent-display=""
                    data-masked={entry.masked ? "" : undefined}
                  >
                    {entry.display}
                  </span>
                  <ScopeBadge scope={entry.scope} />
                </span>
              </div>
            </div>
          ))}
        </div>
      )}
    </>
  );
}

function AgentPanel({
  agent,
  read,
  busy,
  onRun,
}: {
  agent: AgentConfigAgent;
  read: AgentRead;
  busy: boolean;
  onRun: (run: Omit<AgentConfigRun, "agent">) => Promise<string | null>;
}) {
  const [openError, setOpenError] = useState<string | null>(null);
  const state = read.phase === "ready" ? read.state : null;
  return (
    <div className="rows" data-agent-config={agent} data-agent-phase={read.phase}>
      <div className="row">
        <div className="row-main">
          <div className="row-label">
            <div className="row-title">{t(`settingsWindow.agentConfig.agent.${agent}`)}</div>
            {state && (
              <div className="row-help" data-agent-count="">
                {t("settingsWindow.agentConfig.shown", state.keysShown, state.keysOnDisk)}
              </div>
            )}
            {read.phase === "loading" && <div className="row-help">{t("settingsWindow.agentConfig.loading")}</div>}
            {read.phase === "unavailable" && (
              <div className="row-help" data-agent-unavailable="">
                {t("settingsWindow.agentConfig.unavailable")}
              </div>
            )}
            {read.phase === "failed" && (
              <div className="row-error selectable" role="alert" data-agent-read-error="">
                {read.error}
              </div>
            )}
            {state?.notes.map((note) => (
              <div className="row-help" key={note} data-agent-note="">
                {note}
              </div>
            ))}
          </div>
        </div>
      </div>
      {state?.curated.map((row) => (
        <CuratedRow key={row.key} row={row} busy={busy} onRun={onRun} />
      ))}
      {state && (
        <div className="row" data-agent-files="">
          <div className="row-main">
            <div className="row-label">
              <div className="row-title">{t("settingsWindow.agentConfig.files")}</div>
              {openError && (
                <div className="row-error selectable" role="alert" data-agent-open-error="">
                  {openError}
                </div>
              )}
            </div>
          </div>
        </div>
      )}
      {state?.files.map((file) => (
        <div className="row" key={file.path} data-agent-file={file.scope}>
          <div className="row-main">
            <div className="row-label">
              <div className="row-title">{scopeLabel(file.scope)}</div>
              <div className="row-help selectable font-mono">{file.path}</div>
              {file.error && <div className="row-error selectable">{file.error}</div>}
            </div>
            <span className="row-control keys-control">
              <span className="row-help" data-agent-file-state="">
                {file.exists
                  ? t("settingsWindow.agentConfig.keys", file.keys)
                  : t("settingsWindow.agentConfig.fileMissing")}
              </span>
              {!file.writable && <span className="badge">{t("settingsWindow.agentConfig.readOnly")}</span>}
              <Button
                className="button"
                data-agent-action="open"
                disabled={busy || !file.exists}
                aria-label={t("settingsWindow.agentConfig.openFileNamed", scopeLabel(file.scope))}
                onClick={() => void onRun({ verb: "open", path: file.path }).then(setOpenError)}
              >
                {t("settingsWindow.agentConfig.openFile")}
              </Button>
            </span>
          </div>
        </div>
      ))}
      {(state?.profiles?.length ?? 0) > 0 && (
        <div className="row" data-agent-profiles="">
          <div className="row-main">
            <div className="row-label">
              <div className="row-title">{t("settingsWindow.agentConfig.profiles")}</div>
            </div>
          </div>
        </div>
      )}
      {state?.profiles?.map((profile) => (
        <div className="row" key={profile.name} data-agent-profile={profile.name}>
          <div className="row-main">
            <div className="row-label">
              <div className="row-title">{scopeLabel(`profile:${profile.name}`)}</div>
              <div className="row-help selectable font-mono">{profile.path}</div>
            </div>
            <span className="row-control keys-control">
              <span className="row-help">{t("settingsWindow.agentConfig.keys", profile.keys)}</span>
            </span>
          </div>
        </div>
      ))}
      {/* Last: expanding it (hundreds of keys) never moves the Open File buttons above it. */}
      {state && state.entries.length > 0 && <AllSettings state={state} />}
    </div>
  );
}

export function AgentSettingsSection() {
  const store = useStore();
  const root = useRef<HTMLDivElement>(null);
  const mountedAt = useRef<number | null>(null);
  const painted = useRef(false);
  // Recorded at mount, not during render, so the render stays pure.
  useLayoutEffect(() => {
    mountedAt.current = performance.now();
  }, []);
  const [reads, setReads] = useState<Record<AgentConfigAgent, AgentRead>>({
    claude: { phase: "loading" },
    codex: { phase: "loading" },
  });
  const [busy, setBusy] = useState<AgentConfigAgent | null>(null);

  const load = useCallback(
    async (agent: AgentConfigAgent) => {
      const answer = await store.runAgentConfig({ verb: "get", agent });
      const read: AgentRead =
        "error" in answer
          ? { phase: "failed", error: answer.error }
          : "files" in answer
            ? { phase: "ready", state: answer }
            : { phase: "unavailable" };
      setReads((current) => ({ ...current, [agent]: read }));
    },
    [store],
  );
  useEffect(() => {
    for (const agent of AGENT_CONFIG_AGENTS) void load(agent);
  }, [load]);

  // Time to first paint of the data: from mount to both agents drawn (read or failed).
  const settled = AGENT_CONFIG_AGENTS.every((agent) => reads[agent].phase !== "loading");
  useLayoutEffect(() => {
    if (!settled || painted.current || !root.current || mountedAt.current === null) return;
    painted.current = true;
    root.current.dataset.renderMs = String(Math.round(performance.now() - mountedAt.current));
  }, [settled]);

  /** One change or open on `agent`'s settings; the error in plain words, else null. A change
   * reads the agent's settings again. */
  const run = useCallback(
    async (agent: AgentConfigAgent, change: Omit<AgentConfigRun, "agent">): Promise<string | null> => {
      setBusy(agent);
      const attempt = async (): Promise<string | null> => {
        const answer = await store.runAgentConfig({ ...change, agent });
        if ("error" in answer) return answer.error;
        if ("enabled" in answer) return t("settingsWindow.agentConfig.unavailable");
        if (change.verb !== "open") await load(agent);
        return null;
      };
      return attempt().finally(() => setBusy(null));
    },
    [store, load],
  );

  return (
    <div ref={root} data-agent-section="settings">
      <h4 className="group-title">{t("settingsWindow.agentConfig.settings")}</h4>
      {AGENT_CONFIG_AGENTS.map((agent) => (
        <AgentPanel
          key={agent}
          agent={agent}
          read={reads[agent]}
          busy={busy === agent}
          onRun={(change) => run(agent, change)}
        />
      ))}
    </div>
  );
}
