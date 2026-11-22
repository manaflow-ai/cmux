// Settings > Agents > Claude Code & Codex > Skills (Labs `labs.agentCustomization`; nothing shows
// while it is off): every skill and slash command Claude Code and Codex load, from their own folders
// (the app runs `cmux agent-config skills list --json`), grouped by agent, each with its scope, its
// description and its file. Edit opens the file in cmux's editor; Reveal shows it in Finder; the
// switch turns a skill on or off in the agent's own settings (Claude Code `skillOverrides`, Codex
// `[[skills.config]]`), only on a click. A row without a switch has none in its agent (a slash
// command, a Claude Code plugin's skill). The list is read when the card shows.
import { useCallback, useEffect, useId, useMemo, useState } from "react";
import { Button } from "../../../ui/Button";
import { Input } from "../../../ui/Input";
import { AgentMark } from "../../../agent-session/shared/AgentMark";
import { useStore } from "../context";
import { Switch } from "../editors/ToggleEditor";
import type { AgentSkillRow, AgentSkillsRun, AgentSkillsState } from "../ops";
import { t } from "../strings";

/** The agents in the card's order; their names are the products' own, never translated. */
const AGENTS = [
  { id: "claude", name: "Claude Code", sigil: "/" },
  { id: "codex", name: "Codex", sigil: "$" },
] as const;

type Shown = Extract<AgentSkillsState, { enabled: true }>;

function SkillRow({
  row,
  sigil,
  busy,
  refusal,
  onRun,
}: {
  row: AgentSkillRow;
  sigil: string;
  busy: boolean;
  refusal: string | null;
  onRun: (run: AgentSkillsRun) => void;
}) {
  const labelId = useId();
  const tags = [
    row.kind === "command" ? t("settingsWindow.agentSkills.kind.command") : null,
    t(`settingsWindow.agentSkills.scope.${row.scope}`),
    row.plugin ?? null,
    row.override && row.override !== "off" ? row.override : null,
  ].filter((tag): tag is string => !!tag);
  return (
    <div
      className="row accounts-row"
      data-agent-skill={`${row.agent}:${row.name}`}
      data-agent-skill-kind={row.kind}
      data-agent-skill-on={row.enabled ? "true" : "false"}
    >
      <div className="row-main">
        <div className="row-label">
          <div className="row-title font-mono selectable" id={labelId}>
            {sigil}
            {row.name}
          </div>
          <div className="row-help">{tags.join(" · ")}</div>
          {row.description && <div className="row-help selectable agent-skill-description">{row.description}</div>}
          <div className="row-help selectable font-mono agent-skill-path">{row.path}</div>
          {refusal !== null && (
            <div className="row-error selectable" role="alert" data-agent-skill-refusal="">
              {refusal || t("settingsWindow.agentSkills.notChanged")}
            </div>
          )}
        </div>
        <span className="row-control keys-control">
          <Button
            className="button"
            data-agent-skill-action="open"
            aria-describedby={labelId}
            onClick={() => onRun({ action: "open", path: row.path })}
          >
            {t("settingsWindow.agentSkills.edit")}
          </Button>
          <Button
            variant="ghost"
            className="button"
            data-agent-skill-action="reveal"
            aria-describedby={labelId}
            onClick={() => onRun({ action: "reveal", path: row.path })}
          >
            {t("settingsWindow.agentSkills.reveal")}
          </Button>
          {row.switchFile ? (
            <Switch
              checked={row.enabled}
              disabled={busy}
              labelId={labelId}
              onToggle={(next) => onRun({ action: next ? "on" : "off", path: row.path, agent: row.agent })}
            />
          ) : (
            <span className="row-help" data-agent-skill-no-switch="">
              {t(row.enabled ? "settingsWindow.agentSkills.alwaysOn" : "settingsWindow.agentSkills.off")}
            </span>
          )}
        </span>
      </div>
    </div>
  );
}

export function AgentSkillsCard() {
  const store = useStore();
  const [state, setState] = useState<AgentSkillsState | null>(null);
  const [busy, setBusy] = useState(false);
  const [filter, setFilter] = useState("");
  const refresh = useCallback(async () => {
    setState(await store.runAgentSkills({ action: "refresh" }));
  }, [store]);
  useEffect(() => {
    void refresh();
  }, [refresh]);
  const run = useCallback(
    (gesture: AgentSkillsRun) => {
      if (gesture.action === "open" || gesture.action === "reveal") {
        void store.runAgentSkills(gesture);
        return;
      }
      setBusy(true);
      void store
        .runAgentSkills(gesture)
        .then((next) => {
          if (next) setState(next);
        })
        .finally(() => setBusy(false));
    },
    [store],
  );
  const shown: Shown | null = state && state.enabled ? state : null;
  const query = filter.trim().toLowerCase();
  const rows = useMemo(
    () =>
      (shown?.skills ?? []).filter(
        (row) =>
          !query ||
          row.name.toLowerCase().includes(query) ||
          row.description.toLowerCase().includes(query) ||
          row.path.toLowerCase().includes(query),
      ),
    [shown, query],
  );
  // Labs off (or a host without the card): nothing at all.
  if (state === null || !state.enabled) return null;
  const count = (agent: string, kind: string) => {
    const all = state.skills.filter((row) => row.agent === agent && row.kind === kind);
    return { on: all.filter((row) => row.enabled).length, all: all.length };
  };
  return (
    <section className="group" data-card="agentSkills">
      <div className="group-title">{t("settingsWindow.agentSkills.title")}</div>
      <h3 className="row-title">{t("settingsWindow.agentSkills.section")}</h3>
      <div className="row-help">{t("settingsWindow.agentSkills.help")}</div>
      <div className="accounts-header">
        <Input
          type="search"
          className="field"
          data-agent-skills-filter=""
          placeholder={t("settingsWindow.agentSkills.filter")}
          aria-label={t("settingsWindow.agentSkills.filter")}
          value={filter}
          onChange={(event) => setFilter(event.target.value)}
        />
        <Button
          type="button"
          className="button"
          data-agent-skill-action="refresh"
          disabled={state.loading}
          onClick={() => void refresh()}
        >
          {t("settingsWindow.agentSkills.refresh")}
        </Button>
      </div>
      {state.problem && (
        <div className="row-error" data-agent-skills-problem={state.problem}>
          {t(`settingsWindow.agentSkills.problem.${state.problem}`)}
        </div>
      )}
      {state.loading && state.skills.length === 0 && (
        <div className="row-help" data-agent-skills-checking="">
          {t("settingsWindow.agentSkills.checking")}
        </div>
      )}
      {AGENTS.map((agent) => {
        const skills = count(agent.id, "skill");
        const commands = count(agent.id, "command");
        const mine = rows.filter((row) => row.agent === agent.id);
        const skipped = state.problems.filter((problem) => problem.agent === agent.id);
        return (
          <div key={agent.id} data-agent-skills-agent={agent.id}>
            <div className="row-main agent-skills-heading">
              <span className="accounts-mark" aria-hidden="true">
                <AgentMark agent={agent.id} size={16} />
              </span>
              <div className="row-title">{agent.name}</div>
              <div className="row-help" data-agent-skills-count="">
                {t("settingsWindow.agentSkills.skillsOn", skills.on, skills.all)}
                {commands.all > 0 && ` · ${t("settingsWindow.agentSkills.commandsOn", commands.on, commands.all)}`}
              </div>
            </div>
            {mine.length > 0 ? (
              <div className="rows">
                {mine.map((row) => (
                  <SkillRow
                    key={`${row.kind}:${row.path}`}
                    row={row}
                    sigil={agent.sigil}
                    busy={busy}
                    refusal={state.refusal && state.refusal.path === row.path ? state.refusal.message : null}
                    onRun={run}
                  />
                ))}
              </div>
            ) : (
              !state.loading && (
                <div className="row-help" data-agent-skills-empty="">
                  {t("settingsWindow.agentSkills.empty")}
                </div>
              )
            )}
            {skipped.map((problem) => (
              <div className="row-error selectable" key={problem.path} data-agent-skills-skipped="">
                {t("settingsWindow.agentSkills.skipped", problem.path, problem.message)}
              </div>
            ))}
          </div>
        );
      })}
    </section>
  );
}
