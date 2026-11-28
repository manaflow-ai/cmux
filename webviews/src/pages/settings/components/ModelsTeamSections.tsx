import { GroupHeader } from "./GroupHeader";
import { useId, useState } from "react";
import { AgentMark } from "../../../agent-session/shared/AgentMark";
import { Button } from "../../../ui/Button";
import { Input } from "../../../ui/Input";
import { Select } from "../editors/Select";
import { Switch } from "../editors/ToggleEditor";
import type { ModelsState } from "../ops";
import { t } from "../strings";
import { type Run } from "./modelConnections";

const AGENT_NAMES = { claude: "Claude", codex: "Codex" } as const;

export function sharedModelKeyName(agent: keyof typeof AGENT_NAMES) {
  return t("settingsWindow.models.org.key", AGENT_NAMES[agent]);
}

export function OrganizationSection({ models, busy, run }: { models: ModelsState; busy: boolean; run: Run }) {
  const { team, canEdit, keys } = models.organization;
  const [adding, setAdding] = useState(false);
  if (!team) return null;
  const unset = keys.find((key) => !key.set)?.agent ?? null;
  return (
    <section className="group" data-models-section="organization">
      <GroupHeader title={t("settingsWindow.models.team.title")} help={t("settingsWindow.models.team.help")}>
        {canEdit && (
          <Button
            type="button"
            className="button"
            data-models-action="orgAdd"
            disabled={busy || unset === null || adding}
            onClick={() => setAdding(true)}
          >
            {t("settingsWindow.models.org.add")}
          </Button>
        )}
      </GroupHeader>
      <div className="rows models-rows">
        {keys.every((key) => !key.set) && !adding && (
          <div className="row" data-empty="">
            <span className="row-help">{t("settingsWindow.models.org.empty")}</span>
          </div>
        )}
        {keys
          .filter((key) => key.set)
          .map((key) => (
            <OrgKeyRow key={key.agent} agent={key.agent} last4={key.last4} canEdit={canEdit} busy={busy} run={run} />
          ))}
        {canEdit && adding && unset && (
          <OrgKeyForm
            agents={keys.filter((key) => !key.set).map((key) => key.agent)}
            busy={busy}
            run={run}
            onDone={() => setAdding(false)}
          />
        )}
        {!canEdit && (
          <div className="row">
            <span className="row-help" data-models-note="">
              {t("settingsWindow.models.org.readOnly")}
            </span>
          </div>
        )}
      </div>
    </section>
  );
}

function OrgKeyRow({
  agent,
  last4,
  canEdit,
  busy,
  run,
}: {
  agent: "claude" | "codex";
  last4: string | null;
  canEdit: boolean;
  busy: boolean;
  run: Run;
}) {
  const [mode, setMode] = useState<"idle" | "edit" | "confirm">("idle");
  const name = sharedModelKeyName(agent);
  return (
    <div className="row accounts-row" data-org-key={agent}>
      <div className="row-main">
        <span className="accounts-mark" aria-hidden="true">
          <AgentMark agent={agent} size={16} />
        </span>
        <div className="row-label">
          <div className="row-title">{name}</div>
          <div className="row-help">
            {last4 ? t("settingsWindow.models.org.keyEnds", last4) : t("settingsWindow.models.org.keySet")}
          </div>
        </div>
        {canEdit && mode === "idle" && (
          <div className="accounts-buttons">
            <Button
              type="button"
              className="button"
              data-models-action="orgReplace"
              disabled={busy}
              onClick={() => setMode("edit")}
            >
              {t("settingsWindow.models.org.replace")}
            </Button>
            <Button
              danger
              type="button"
              className="button danger"
              data-models-action="orgRemove"
              disabled={busy}
              onClick={() => setMode("confirm")}
            >
              {t("settingsWindow.remove")}
            </Button>
          </div>
        )}
      </div>
      {canEdit && mode === "confirm" && (
        <div className="accounts-body">
          <div className="accounts-form" role="alertdialog">
            <span className="row-help">{t("settingsWindow.models.org.removeConfirm", name)}</span>
            <div className="accounts-buttons">
              <Button
                danger
                type="button"
                className="button danger"
                data-models-action="orgConfirmRemove"
                disabled={busy}
                onClick={() => {
                  setMode("idle");
                  void run({ action: "orgKey", agent, key: null });
                }}
              >
                {t("settingsWindow.remove")}
              </Button>
              <Button type="button" className="button" onClick={() => setMode("idle")}>
                {t("settingsWindow.cancel")}
              </Button>
            </div>
          </div>
        </div>
      )}
      {canEdit && mode === "edit" && (
        <div className="accounts-body">
          <OrgKeyForm agents={[agent]} busy={busy} run={run} onDone={() => setMode("idle")} />
        </div>
      )}
    </div>
  );
}

function OrgKeyForm({
  agents,
  busy,
  run,
  onDone,
}: {
  agents: Array<"claude" | "codex">;
  busy: boolean;
  run: Run;
  onDone(): void;
}) {
  const agentLabel = useId();
  const [agent, setAgent] = useState(agents[0] ?? "claude");
  const [key, setKey] = useState("");
  const send = () => {
    const value = key.trim();
    if (!value || busy) return;
    // The key leaves the page's state before it is sent.
    setKey("");
    void run({ action: "orgKey", agent, key: value }).then((ok) => {
      if (ok) onDone();
    });
  };
  return (
    <form
      className="accounts-form"
      data-org-key-form=""
      onSubmit={(event) => {
        event.preventDefault();
        send();
      }}
    >
      {agents.length > 1 && (
        <div className="row-main">
          <div className="row-label">
            <div className="row-title" id={agentLabel}>
              {t("settingsWindow.models.org.agent")}
            </div>
          </div>
          <div className="row-control">
            <Select
              value={agent}
              disabled={busy}
              labelId={agentLabel}
              onChange={(value) => setAgent(value === "codex" ? "codex" : "claude")}
            >
              {agents.map((option) => (
                <option key={option} value={option}>
                  {AGENT_NAMES[option]}
                </option>
              ))}
            </Select>
          </div>
        </div>
      )}
      <Input
        className="field"
        type="password"
        aria-label={t("settingsWindow.models.key.field")}
        autoComplete="off"
        spellCheck={false}
        maxLength={4096}
        value={key}
        onChange={(event) => setKey(event.target.value)}
      />
      <div className="accounts-buttons">
        <Button type="submit" className="button" data-models-action="orgSave" disabled={busy || !key.trim()}>
          {t("settingsWindow.models.key.add")}
        </Button>
        <Button
          type="button"
          className="button"
          onClick={() => {
            setKey("");
            onDone();
          }}
        >
          {t("settingsWindow.cancel")}
        </Button>
      </div>
    </form>
  );
}

export function MembersSection({
  members,
  busy,
  run,
}: {
  members: NonNullable<ModelsState["members"]>;
  busy: boolean;
  run: Run;
}) {
  const ownId = useId();
  const runoutId = useId();
  const rows = [
    {
      id: ownId,
      row: "ownConnections",
      title: t("settingsWindow.models.members.own"),
      checked: members.ownConnections,
      toggle: (on: boolean) => void run({ action: "members", ownConnections: on }),
    },
    {
      id: runoutId,
      row: "chooseRunout",
      title: t("settingsWindow.models.members.runout"),
      checked: members.chooseRunout,
      toggle: (on: boolean) => void run({ action: "members", chooseRunout: on }),
    },
  ];
  return (
    <section className="group" data-models-section="members">
      <GroupHeader title={t("settingsWindow.models.members.title")} help={t("settingsWindow.models.members.help")} />
      <div className="rows models-rows">
        {rows.map((row) => (
          <div className="row" key={row.row} data-models-row={row.row}>
            <div className="row-main">
              <div className="row-label" id={row.id}>
                <div className="row-title">{row.title}</div>
              </div>
              <div className="row-control">
                <Switch checked={row.checked} disabled={busy} labelId={row.id} onToggle={row.toggle} />
              </div>
            </div>
          </div>
        ))}
      </div>
    </section>
  );
}
