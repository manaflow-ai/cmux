// Settings > Agents > Agent integrations: optional help for the coding-agent hooks that tell cmux
// when an agent is working, waiting or done. The host reads `cmux agent hook status` and runs
// `agent hook install|uninstall <id>` (cmux.settings.integrations.run); the CLI owns every write
// and refuses to replace a file it did not create. Collapsed until opened (the route's focus
// `agents.integrations` opens it), it reads status only once open and changes nothing without a
// click. A row whose file is in the way (`conflict`) offers no Install: it says what is there and
// gives the command to run by hand once it is moved.
import { useCallback, useId, useRef, useState } from "react";
import { agentDisplayName } from "../../../agent-session/acpmux/agents";
import { AgentMark } from "../../../agent-session/shared/AgentMark";
import { useStore } from "../context";
import type { IntegrationRow, IntegrationsRun, IntegrationsState } from "../ops";
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
            <button
              key={gesture}
              type="button"
              className="button"
              data-integration-action={gesture}
              aria-describedby={titleId}
              disabled={busy}
              onClick={() => onRun(gesture)}
            >
              {t(`settingsWindow.agentIntegrations.${gesture}`)}
            </button>
          ))}
          {row.state === "conflict" && (
            <button
              type="button"
              className="button"
              data-integration-action="copy"
              aria-describedby={titleId}
              onClick={() => onCopy(manual)}
            >
              {t("settingsWindow.agentIntegrations.copy")}
            </button>
          )}
        </div>
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
    async (id: string, gesture: Gesture) => {
      setBusy(id);
      try {
        setState(await store.runIntegrations({ action: gesture, id }));
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
          <button
            type="button"
            className="button"
            data-integration-action="refresh"
            disabled={state?.loading ?? false}
            onClick={() => void refresh()}
          >
            {t("settingsWindow.agentIntegrations.refresh")}
          </button>
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
          <button
            type="button"
            className="button"
            data-integration-action="copyAll"
            onClick={() => void store.copy(command)}
          >
            {t("settingsWindow.agentIntegrations.copy")}
          </button>
        </div>
      </details>
    </section>
  );
}
