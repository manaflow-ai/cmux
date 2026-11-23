// Settings > Agents > Claude Code & Codex > Skills (Labs `labs.agentCustomization`; nothing shows
// while it is off): every skill and slash command Claude Code and Codex load, from their own folders
// (the app runs `cmux agent-config skills list --json`), grouped by agent, each with its scope, its
// description and its file. Edit opens the file in cmux's editor; Reveal shows it in Finder; the
// switch turns a skill on or off in the agent's own settings (Claude Code `skillOverrides`, Codex
// `[[skills.config]]`), only on a click. A row without a switch has none in its agent (a slash
// command, a Claude Code plugin's skill). The list is read when the card shows. New Command saves a
// prompt as a slash command (`cmux agent-config commands add`): Claude Code's `/NAME`, Codex's
// `/prompts:NAME`, or cmux's own, which every chat's `/` menu lists whatever its agent.
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

/** Where New Command can save: the agents' own folders, or cmux's saved prompts. */
type CommandAgent = Extract<AgentSkillsRun, { action: "add" }>["agent"];
const COMMAND_AGENTS: ReadonlyArray<{ id: CommandAgent; name: () => string }> = [
  { id: "claude", name: () => "Claude Code" },
  { id: "codex", name: () => "Codex" },
  { id: "cmux", name: () => t("settingsWindow.agentSkills.newCommand.everyChat") },
];
/** The refusal path the host gives a New Command it could not save. */
const NEW_COMMAND = "new-command";
/** A name every agent reads as one word (cmux-agent-customize `commands::valid_name`). */
const COMMAND_NAME = /^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$/;

function NewCommandForm({
  busy,
  refusal,
  added,
  onAdd,
}: {
  busy: boolean;
  refusal: string | null;
  added: Shown["added"];
  onAdd: (run: AgentSkillsRun) => Promise<Shown | null>;
}) {
  const [open, setOpen] = useState(false);
  const [agent, setAgent] = useState<CommandAgent>("claude");
  const [name, setName] = useState("");
  const [description, setDescription] = useState("");
  const [prompt, setPrompt] = useState("");
  const typed = name.trim().replace(/^\//, "");
  const nameOk = COMMAND_NAME.test(typed) && !typed.includes("..") && !typed.endsWith(".md");
  const saved =
    added && !open ? (
      <div className="row-help selectable" data-agent-command-added="">
        {t("settingsWindow.agentSkills.newCommand.saved", added.invocation, added.path)}
      </div>
    ) : null;
  if (!open) {
    return (
      <>
        <Button className="button" data-agent-skill-action="newCommand" onClick={() => setOpen(true)}>
          {t("settingsWindow.agentSkills.newCommand")}
        </Button>
        {saved}
      </>
    );
  }
  return (
    // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
    <div
      className="accounts-form"
      data-agent-command-form=""
      role="group"
      aria-label={t("settingsWindow.agentSkills.newCommand")}
    >
      <label className="row-help">
        {t("settingsWindow.agentSkills.newCommand.agent")}{" "}
        <select
          data-agent-command-field="agent"
          value={agent}
          onChange={(change) => setAgent(change.target.value as CommandAgent)}
        >
          {COMMAND_AGENTS.map((entry) => (
            <option key={entry.id} value={entry.id}>
              {entry.name()}
            </option>
          ))}
        </select>
      </label>
      <label className="row-help">
        {t("settingsWindow.agentSkills.newCommand.name")}{" "}
        <input
          data-agent-command-field="name"
          aria-label={t("settingsWindow.agentSkills.newCommand.name")}
          className="font-mono"
          value={name}
          placeholder="standup"
          onChange={(change) => setName(change.target.value)}
        />
      </label>
      <label className="row-help">
        {t("settingsWindow.agentSkills.newCommand.description")}{" "}
        <input
          data-agent-command-field="description"
          aria-label={t("settingsWindow.agentSkills.newCommand.description")}
          value={description}
          onChange={(change) => setDescription(change.target.value)}
        />
      </label>
      <label className="row-help">
        {t("settingsWindow.agentSkills.newCommand.prompt")}
        <textarea
          data-agent-command-field="prompt"
          aria-label={t("settingsWindow.agentSkills.newCommand.prompt")}
          rows={4}
          value={prompt}
          onChange={(change) => setPrompt(change.target.value)}
        />
      </label>
      <div className="row-help">
        {t(
          "settingsWindow.agentSkills.newCommand.where",
          agent === "codex" ? `/prompts:${typed || "NAME"}` : `/${typed || "NAME"}`,
        )}
      </div>
      {refusal !== null && (
        <div className="row-error selectable" role="alert" data-agent-command-refusal="">
          {refusal || t("settingsWindow.agentSkills.notChanged")}
        </div>
      )}
      <div className="accounts-buttons">
        <Button
          className="button"
          data-agent-skill-action="confirmNewCommand"
          disabled={busy || !nameOk || prompt.trim() === ""}
          onClick={() =>
            void onAdd({
              action: "add",
              agent,
              name: typed,
              prompt,
              ...(description.trim() ? { description: description.trim() } : {}),
            }).then((next) => {
              if (next && next.refusal?.path !== NEW_COMMAND) {
                setOpen(false);
                setName("");
                setDescription("");
                setPrompt("");
              }
            })
          }
        >
          {t("settingsWindow.agentSkills.newCommand.save")}
        </Button>
        <Button className="button" data-agent-skill-action="cancelNewCommand" onClick={() => setOpen(false)}>
          {t("settingsWindow.agentSkills.newCommand.cancel")}
        </Button>
      </div>
    </div>
  );
}

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
  const write = useCallback(
    async (gesture: AgentSkillsRun): Promise<Shown | null> => {
      setBusy(true);
      try {
        const next = await store.runAgentSkills(gesture);
        if (next) setState(next);
        return next && next.enabled ? next : null;
      } finally {
        setBusy(false);
      }
    },
    [store],
  );
  const run = useCallback(
    (gesture: AgentSkillsRun) => {
      if (gesture.action === "open" || gesture.action === "reveal") {
        void store.runAgentSkills(gesture);
        return;
      }
      void write(gesture);
    },
    [store, write],
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
      <div className="accounts-header" data-agent-command-new="">
        <NewCommandForm
          busy={busy}
          refusal={state.refusal && state.refusal.path === NEW_COMMAND ? state.refusal.message : null}
          added={state.added ?? null}
          onAdd={write}
        />
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
