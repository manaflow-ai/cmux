// Settings > Agents > Agent integrations: optional help for the coding-agent hooks that tell cmux
// when an agent is working, waiting or done. The host reads `cmux agent hook status` and runs
// `agent hook install|uninstall <id>` (cmux.settings.integrations.run); the CLI owns every write
// and refuses to replace a file it did not create. Collapsed until opened (the route's focus
// `agents.integrations` opens it), it reads status only once open and changes nothing without a
// click. A row whose file is in the way (`conflict`) offers no Install: it says what is there and
// gives the command to run by hand once it is moved.
import { useCallback, useId, useRef, useState } from "react";
import { Button } from "../../../ui/Button";
import { agentDisplayName } from "../../../agent-session/acpmux/agents";
import { AgentMark } from "../../../agent-session/shared/AgentMark";
import { useStore } from "../context";
import type { IntegrationRow, IntegrationsRun, IntegrationsState, SkillsState } from "../ops";
import { t } from "../strings";

type Gesture = Exclude<IntegrationsRun["action"], "refresh">;

/** What a row offers: Install when absent, Repair and Remove when partial, Remove when installed. */
function gestures(row: IntegrationRow): Gesture[] {
  switch (row.state) {
    case "absent":
      return ["install"];
    case "partial":
      return ["repair", "remove"];
    case "installed":
      return ["remove"];
    default:
      return [];
  }
}

function Row({
  row,
  command,
  busy,
  onRun,
  onCopy,
}: {
  row: IntegrationRow;
  command: string;
  busy: boolean;
  onRun: (gesture: Gesture) => void;
  onCopy: (text: string) => void;
}) {
  const titleId = useId();
  const blocked = row.state === "conflict" || row.state === "unavailable";
  const manual = `${command} ${row.id}`;
  return (
    <div className="row accounts-row" data-integration={row.id} data-integration-state={row.state}>
      <div className="row-main">
        <span className="accounts-mark" aria-hidden="true">
          <AgentMark agent={row.id} size={16} />
        </span>
        <div className="row-label">
          <div className="row-title" id={titleId}>
            {agentDisplayName(row.id)}
          </div>
          {row.path && <div className="row-help selectable font-mono">{row.path}</div>}
          {blocked && (
            <div className="row-help" data-integration-reason={row.reason ?? "unreadable"}>
              {t(`settingsWindow.agentIntegrations.conflict.${row.reason ?? "unreadable"}`)}
            </div>
          )}
          {blocked && row.state === "conflict" && (
            // The command to run once the file is moved: a value to copy, on its own line.
            <div className="row-help selectable">
              <code className="font-mono" data-integration-command="">
                {manual}
              </code>
            </div>
          )}
          {(row.error || row.errorKind) && (
            <div className="row-error selectable" data-integration-error={row.errorKind ?? ""}>
              {row.error ?? t(`settingsWindow.agentIntegrations.error.${row.errorKind}`)}
            </div>
          )}
        </div>
        <div className="row-control">
          <span
            className={blocked || row.state === "partial" ? "badge badge-warning" : "badge"}
            data-integration-badge=""
          >
            {t(`settingsWindow.agentIntegrations.state.${row.state}`)}
          </span>
          {gestures(row).map((gesture) => (
            <Button
              key={gesture}
              type="button"
              className="button"
              data-integration-action={gesture}
              aria-describedby={titleId}
              disabled={busy}
              onClick={() => onRun(gesture)}
            >
              {t(`settingsWindow.agentIntegrations.${gesture}`)}
            </Button>
          ))}
          {row.state === "conflict" && (
            <Button
              type="button"
              className="button"
              data-integration-action="copy"
              aria-describedby={titleId}
              onClick={() => onCopy(manual)}
            >
              {t("settingsWindow.agentIntegrations.copy")}
            </Button>
          )}
        </div>
      </div>
    </div>
  );
}

/** A skills folder's gestures: as the hooks', plus Remove on a conflict, which takes out only the
 * skills cmux wrote there and leaves the person's own folder. */
function skillGestures(row: IntegrationRow): Gesture[] {
  return row.state === "conflict" ? ["remove"] : gestures(row);
}

/** One global skills folder (`claude`, `agents`): what it holds and the gestures its state allows.
 * Its own data attributes, so the hook rows' (`data-integration`) stay one agent each. */
function SkillsRow({
  row,
  command,
  busy,
  onRun,
  onCopy,
}: {
  row: IntegrationRow;
  command: string;
  busy: boolean;
  onRun: (gesture: Gesture) => void;
  onCopy: (text: string) => void;
}) {
  const titleId = useId();
  const blocked = row.state === "conflict" || row.state === "unavailable";
  const manual = `${command} ${row.id}`;
  return (
    <div className="row accounts-row" data-skills-target={row.id} data-skills-state={row.state}>
      <div className="row-main">
        <span className="accounts-mark" aria-hidden="true">
          <AgentMark agent={row.id === "claude" ? "claude" : "codex"} size={16} />
        </span>
        <div className="row-label">
          <div className="row-title" id={titleId}>
            {t(`settingsWindow.agentIntegrations.skills.target.${row.id === "claude" ? "claude" : "agents"}`)}
          </div>
          {row.path && <div className="row-help selectable font-mono">{row.path}</div>}
          {blocked && (
            <div className="row-help" data-skills-reason={row.reason ?? "unreadable"}>
              {row.reason === "not_owned"
                ? t("settingsWindow.agentIntegrations.skills.conflict")
                : t(`settingsWindow.agentIntegrations.conflict.${row.reason ?? "unreadable"}`)}
            </div>
          )}
          {(row.error || row.errorKind) && (
            <div className="row-error selectable" data-skills-error={row.errorKind ?? ""}>
              {row.error ?? t(`settingsWindow.agentIntegrations.error.${row.errorKind}`)}
            </div>
          )}
        </div>
        <div className="row-control">
          <span className={blocked || row.state === "partial" ? "badge badge-warning" : "badge"}>
            {t(`settingsWindow.agentIntegrations.state.${row.state}`)}
          </span>
          {skillGestures(row).map((gesture) => (
            <Button
              key={gesture}
              type="button"
              className="button"
              data-skills-action={gesture}
              aria-describedby={titleId}
              disabled={busy}
              onClick={() => onRun(gesture)}
            >
              {t(`settingsWindow.agentIntegrations.${gesture}`)}
            </Button>
          ))}
          {row.state === "conflict" && (
            <Button
              type="button"
              className="button"
              data-skills-action="copy"
              aria-describedby={titleId}
              onClick={() => onCopy(manual)}
            >
              {t("settingsWindow.agentIntegrations.copy")}
            </Button>
          )}
        </div>
      </div>
    </div>
  );
}

/** cmux skills for agents started outside cmux's chats: off until the person installs them. */
function SkillsSection({
  skills,
  busy,
  onRun,
  onCopy,
}: {
  skills: SkillsState;
  busy: boolean;
  onRun: (id: string, gesture: Gesture) => void;
  onCopy: (text: string) => void;
}) {
  return (
    <div data-skills-section="">
      <div className="row-title">{t("settingsWindow.agentIntegrations.skills.title")}</div>
      <div className="row-help">{t("settingsWindow.agentIntegrations.skills.help")}</div>
      {skills.problem && (
        <div className="row-error" data-skills-problem={skills.problem}>
          {t(`settingsWindow.agentIntegrations.problem.${skills.problem}`)}
        </div>
      )}
      {skills.providers.length > 0 && (
        <div className="rows">
          {skills.providers.map((row) => (
            <SkillsRow
              key={row.id}
              row={row}
              command={skills.command}
              busy={busy}
              onRun={(gesture) => onRun(row.id, gesture)}
              onCopy={onCopy}
            />
          ))}
        </div>
      )}
      <div className="row-help">{t("settingsWindow.agentIntegrations.skills.manual")}</div>
      <div className="row-help selectable flex items-center gap-2">
        <code className="font-mono" data-skills-command="">
          {skills.command}
        </code>
        <Button type="button" className="button" data-skills-action="copyAll" onClick={() => onCopy(skills.command)}>
          {t("settingsWindow.agentIntegrations.copy")}
        </Button>
      </div>
    </div>
  );
}

export function AgentIntegrations({ focus }: { focus: string | null }) {
  const store = useStore();
  const [open, setOpen] = useState(focus === "agents.integrations");
  const [state, setState] = useState<IntegrationsState | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const read = useRef(false);
  const refresh = useCallback(async () => {
    setState(await store.runIntegrations({ action: "refresh" }));
  }, [store]);
  // Status is read the first time the card opens, never before: a closed card runs nothing.
  const details = useCallback(
    (node: HTMLDetailsElement | null) => {
      if (node?.open && !read.current) {
        read.current = true;
        void refresh();
      }
    },
    [refresh],
  );
  const run = useCallback(
    async (id: string, gesture: Gesture, kind: "hooks" | "skills" = "hooks") => {
      setBusy(id);
      try {
        setState(
          await store.runIntegrations(kind === "skills" ? { action: gesture, id, kind } : { action: gesture, id }),
        );
      } finally {
        setBusy(null);
      }
    },
    [store],
  );
  const command = state?.command ?? "cmux agent hook install";
  return (
    <section className="group" data-card="agentIntegrations">
      <details
        ref={details}
        open={open}
        onToggle={(event) => {
          const now = event.currentTarget.open;
          setOpen(now);
          if (now && !read.current) {
            read.current = true;
            void refresh();
          }
        }}
      >
        <summary className="group-title cursor-default select-none" data-integrations-toggle="">
          {t("settingsWindow.agentIntegrations.title")}
        </summary>
        <div className="row-help">{t("settingsWindow.agentIntegrations.help")}</div>
        <div className="accounts-header">
          <Button
            type="button"
            className="button"
            data-integration-action="refresh"
            disabled={state?.loading ?? false}
            onClick={() => void refresh()}
          >
            {t("settingsWindow.agentIntegrations.refresh")}
          </Button>
        </div>
        {state?.problem && (
          <div className="row-error" data-integrations-problem={state.problem}>
            {t(`settingsWindow.agentIntegrations.problem.${state.problem}`)}
          </div>
        )}
        {open && !state && (
          <div className="row-help" data-integrations-checking="">
            {t("settingsWindow.agentIntegrations.checking")}
          </div>
        )}
        {state && state.providers.length > 0 && (
          <div className="rows">
            {state.providers.map((row) => (
              <Row
                key={row.id}
                row={row}
                command={command}
                busy={busy !== null}
                onRun={(gesture) => void run(row.id, gesture)}
                onCopy={(text) => void store.copy(text)}
              />
            ))}
          </div>
        )}
        <div className="row-help">{t("settingsWindow.agentIntegrations.restart")}</div>
        <div className="row-help">{t("settingsWindow.agentIntegrations.manual")}</div>
        <div className="row-help selectable flex items-center gap-2">
          <code className="font-mono" data-integrations-command="">
            {command}
          </code>
          <Button
            type="button"
            className="button"
            data-integration-action="copyAll"
            onClick={() => void store.copy(command)}
          >
            {t("settingsWindow.agentIntegrations.copy")}
          </Button>
        </div>
        {state?.skills && (
          <SkillsSection
            skills={state.skills}
            busy={busy !== null}
            onRun={(id, gesture) => void run(id, gesture, "skills")}
            onCopy={(text) => void store.copy(text)}
          />
        )}
      </details>
    </section>
  );
}
