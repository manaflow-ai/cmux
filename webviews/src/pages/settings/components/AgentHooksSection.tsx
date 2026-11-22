// Settings > Agents > Claude Code & Codex > Hooks (Labs `labs.agentCustomization`; the card shell,
// AgentCustomizationCard, draws nothing while it is off). Leo, 2026-11-19: "Claude Code, Codex and
// Rex customization visible in cmux"; "actually looking at the functionality, testing it out". Read and written by the bundled
// `cmux agent-config hooks` (cmux-tui/crates/cmux-agent-customize) through SettingsAgentHooks in the app.
// Every Claude Code and Codex hook on this Mac by agent and event, with its matcher, command,
// where it lives and whether it runs. Turn Off / Turn On and Remove act on the person's own hooks;
// cmux's own and plugin hooks are shown read-only. Add writes a new command hook. Nothing changes
// without a click.
import { useCallback, useEffect, useId, useMemo, useState } from "react";
import { Button } from "../../../ui/Button";
import { useStore } from "../context";
import type { AgentHookRow, AgentHooksRun, AgentHooksState } from "../ops";
import { t } from "../strings";
import { WithFacts } from "../../../agent-session/acpmux/chips/FactsHoverCard";

/** Product names, never translated. */
const AGENT_NAMES = { claude: "Claude Code", codex: "Codex" } as const;

/** The events Add offers per agent (cmux-agent-customize CLAUDE_EVENTS / CODEX_EVENTS, the common ones first). */
const ADD_EVENTS = {
  claude: [
    "PreToolUse",
    "PostToolUse",
    "UserPromptSubmit",
    "Stop",
    "SubagentStop",
    "SessionStart",
    "SessionEnd",
    "Notification",
    "PreCompact",
    "PermissionRequest",
  ],
  codex: [
    "PreToolUse",
    "PostToolUse",
    "UserPromptSubmit",
    "Stop",
    "SubagentStop",
    "SessionStart",
    "SessionEnd",
    "PreCompact",
    "PermissionRequest",
  ],
} as const;

type Agent = keyof typeof AGENT_NAMES;

function HookRow({
  hook,
  busy,
  onRun,
}: {
  hook: AgentHookRow;
  busy: boolean;
  onRun: (action: "enable" | "disable" | "remove") => void;
}) {
  const titleId = useId();
  const commandId = useId();
  const [confirming, setConfirming] = useState(false);
  const tags = [
    AGENT_NAMES[hook.agent],
    t(`settingsWindow.agentHooks.scope.${hook.scope}`),
    hook.owner === "cmux" ? t("settingsWindow.agentHooks.owner.cmux") : null,
    hook.owner === "plugin" ? (hook.plugin ?? t("settingsWindow.agentHooks.owner.plugin")) : null,
    hook.trust && hook.trust !== "trusted" ? t(`settingsWindow.agentHooks.trust.${hook.trust}`) : null,
  ].filter((part): part is string => !!part);
  return (
    // One group per hook, named by its event, matcher and command (VoiceOver and the accessibility tree).
    <div
      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
      role="group"
      className="row accounts-row"
      aria-labelledby={`${titleId} ${commandId}`}
      data-agent-hook={hook.id}
      data-hook-agent={hook.agent}
      data-hook-enabled={hook.enabled ? "true" : "false"}
      data-hook-owner={hook.owner}
    >
      <div className="row-main">
        <div className="row-label">
          <div className="row-title" id={titleId}>
            {hook.event}
            {hook.matcher && (
              <span className="row-help font-mono" data-hook-matcher="">
                {" "}
                {hook.matcher}
              </span>
            )}
          </div>
          <WithFacts facts={[{ value: hook.file, code: true }]}>
            {(facts) => (
              <div {...facts} className="row-help selectable font-mono" id={commandId} data-hook-command="">
                {hook.command}
              </div>
            )}
          </WithFacts>
          <div className="row-help">{tags.join(" · ")}</div>
        </div>
        <span className="row-control keys-control">
          <span
            className="accounts-status devices-status"
            data-tone={hook.enabled ? "success" : "neutral"}
            data-hook-status=""
          >
            <span className="accounts-dot" aria-hidden="true" />
            {t(hook.enabled ? "settingsWindow.agentHooks.on" : "settingsWindow.agentHooks.off")}
          </span>
          {!hook.read_only && !confirming && (
            <Button
              className="button"
              data-hook-action={hook.enabled ? "disable" : "enable"}
              aria-describedby={titleId}
              disabled={busy}
              onClick={() => onRun(hook.enabled ? "disable" : "enable")}
            >
              {t(hook.enabled ? "settingsWindow.agentHooks.turnOff" : "settingsWindow.agentHooks.turnOn")}
            </Button>
          )}
          {!hook.read_only && !confirming && (
            <Button
              danger
              variant="ghost"
              className="button"
              data-hook-action="remove"
              aria-describedby={titleId}
              disabled={busy}
              onClick={() => setConfirming(true)}
            >
              {t("settingsWindow.agentHooks.remove")}
            </Button>
          )}
        </span>
      </div>
      {confirming && (
        // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
        <div className="accounts-form" data-hook-confirm="" role="group" aria-labelledby={titleId}>
          <div className="row-help">{t("settingsWindow.agentHooks.removeBody")}</div>
          <div className="accounts-buttons">
            <Button
              danger
              variant="ghost"
              className="button"
              data-hook-action="confirmRemove"
              disabled={busy}
              onClick={() => {
                setConfirming(false);
                onRun("remove");
              }}
            >
              {t("settingsWindow.agentHooks.remove")}
            </Button>
            <Button className="button" data-hook-action="cancel" onClick={() => setConfirming(false)}>
              {t("settingsWindow.agentHooks.cancel")}
            </Button>
          </div>
        </div>
      )}
    </div>
  );
}

function AddHookForm({ busy, onAdd }: { busy: boolean; onAdd: (run: AgentHooksRun) => Promise<void> }) {
  const [open, setOpen] = useState(false);
  const [agent, setAgent] = useState<Agent>("claude");
  const [event, setEvent] = useState<string>("PreToolUse");
  const [matcher, setMatcher] = useState("");
  const [command, setCommand] = useState("");
  if (!open) {
    return (
      <Button className="button" data-hook-action="add" onClick={() => setOpen(true)}>
        {t("settingsWindow.agentHooks.add")}
      </Button>
    );
  }
  return (
    // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role
    <div className="accounts-form" data-hook-add-form="" role="group" aria-label={t("settingsWindow.agentHooks.add")}>
      <label className="row-help">
        {t("settingsWindow.agentHooks.agent")}{" "}
        <select
          data-hook-field="agent"
          value={agent}
          onChange={(change) => {
            const next = change.target.value as Agent;
            setAgent(next);
            if (!(ADD_EVENTS[next] as readonly string[]).includes(event)) setEvent("PreToolUse");
          }}
        >
          {(Object.keys(AGENT_NAMES) as Agent[]).map((id) => (
            <option key={id} value={id}>
              {AGENT_NAMES[id]}
            </option>
          ))}
        </select>
      </label>
      <label className="row-help">
        {t("settingsWindow.agentHooks.event")}{" "}
        <select data-hook-field="event" value={event} onChange={(change) => setEvent(change.target.value)}>
          {ADD_EVENTS[agent].map((name) => (
            <option key={name} value={name}>
              {name}
            </option>
          ))}
        </select>
      </label>
      <label className="row-help">
        {t("settingsWindow.agentHooks.matcher")}{" "}
        <input
          data-hook-field="matcher"
          aria-label={t("settingsWindow.agentHooks.matcher")}
          className="font-mono"
          value={matcher}
          placeholder="Bash"
          onChange={(change) => setMatcher(change.target.value)}
        />
      </label>
      <label className="row-help">
        {t("settingsWindow.agentHooks.command")}{" "}
        <input
          data-hook-field="command"
          aria-label={t("settingsWindow.agentHooks.command")}
          className="font-mono"
          value={command}
          onChange={(change) => setCommand(change.target.value)}
        />
      </label>
      <div className="accounts-buttons">
        <Button
          className="button"
          data-hook-action="confirmAdd"
          disabled={busy || command.trim() === ""}
          onClick={() =>
            void onAdd({
              action: "add",
              agent,
              event,
              command: command.trim(),
              ...(matcher.trim() ? { matcher: matcher.trim() } : {}),
            }).then(() => {
              setOpen(false);
              setCommand("");
              setMatcher("");
            })
          }
        >
          {t("settingsWindow.agentHooks.addConfirm")}
        </Button>
        <Button className="button" data-hook-action="cancelAdd" onClick={() => setOpen(false)}>
          {t("settingsWindow.agentHooks.cancel")}
        </Button>
      </div>
    </div>
  );
}

export function AgentHooksSection() {
  const store = useStore();
  const [state, setState] = useState<AgentHooksState | null>(null);
  const [busy, setBusy] = useState(false);
  const [agent, setAgent] = useState<Agent | "all">("all");
  const run = useCallback(
    (gesture: AgentHooksRun) => {
      setBusy(true);
      return store
        .runAgentHooks(gesture)
        .then(setState)
        .finally(() => setBusy(false));
    },
    [store],
  );
  useEffect(() => {
    void run({ action: "refresh" });
  }, [run]);
  const listing = state?.available ? state.listing : null;
  const shown = useMemo(
    () => (listing?.hooks ?? []).filter((hook) => agent === "all" || hook.agent === agent),
    [listing, agent],
  );
  // A host without the part: nothing (the shell already draws nothing while Labs is off).
  if (!state || !state.available) return null;
  return (
    <div data-agent-customization-section="hooks">
      <div className="group-subtitle row-title">{t("settingsWindow.agentHooks.title")}</div>
      <div className="row-help">{t("settingsWindow.agentHooks.help")}</div>
      <div className="accounts-header">
        {listing && (
          <span className="row-help" data-hook-counts="">
            {t("settingsWindow.agentHooks.counts", listing.counts.claude, listing.counts.codex)}
          </span>
        )}
        {/* oxlint-disable-next-line jsx-a11y/prefer-tag-over-role */}
        <span role="group" aria-label={t("settingsWindow.agentHooks.agent")}>
          {(["all", "claude", "codex"] as const).map((id) => (
            <Button
              key={id}
              className="button"
              variant={agent === id ? undefined : "ghost"}
              aria-pressed={agent === id}
              data-hook-filter={id}
              onClick={() => setAgent(id)}
            >
              {id === "all" ? t("settingsWindow.agentHooks.all") : AGENT_NAMES[id]}
            </Button>
          ))}
        </span>
        <Button
          type="button"
          className="button"
          data-hook-action="refresh"
          disabled={busy}
          onClick={() => void run({ action: "refresh" })}
        >
          {t("settingsWindow.agentHooks.refresh")}
        </Button>
      </div>
      {listing?.codex_hooks_feature === false && (
        <div className="row-help" data-hook-codex-feature-off="">
          {t("settingsWindow.agentHooks.codexFeatureOff")}
        </div>
      )}
      {listing?.files
        .filter((file) => file.disable_all_hooks)
        .map((file) => (
          <div className="row-help" key={file.path} data-hook-disable-all={file.path}>
            {t("settingsWindow.agentHooks.disableAll", file.path)}
          </div>
        ))}
      {state.error && (
        <div className="row-error selectable" role="alert" data-hook-error="">
          {state.error}
        </div>
      )}
      {!listing && !state.error && (
        <div className="row-help" data-hook-checking="">
          {t("settingsWindow.agentHooks.checking")}
        </div>
      )}
      {listing && shown.length === 0 && (
        <div className="row-help" data-hook-empty="">
          {t("settingsWindow.agentHooks.empty")}
        </div>
      )}
      {shown.length > 0 && (
        <div className="rows" data-hook-rows="">
          {shown.map((hook) => (
            <HookRow key={hook.id} hook={hook} busy={busy} onRun={(action) => void run({ action, id: hook.id })} />
          ))}
        </div>
      )}
      <div className="accounts-header">
        <AddHookForm busy={busy} onAdd={run} />
      </div>
    </div>
  );
}
