// Settings > Agents > Agent integrations: optional help for the coding-agent hooks that tell cmux
// when an agent is working, waiting or done. The host reads `cmux agent hook status` and runs
// `agent hook install|uninstall <id>` (cmux.settings.integrations.run); the CLI owns every write
// and refuses to replace a file it did not create. Collapsed until opened (the route's focus
// `agents.integrations` opens it), it reads status only once open and changes nothing without a
// click. A row whose file is in the way (`conflict`) offers no Install: it says what is there and
// gives the command to run by hand once it is moved.
//
// The `link-<app>` rows come first, under "Your other apps": the cmux MCP server in Claude desktop,
// Claude Code and the Codex desktop app (`acpmux desktop link`), with Connect, Reconnect (an entry
// another cmux build wrote) and Disconnect. Leo, 2026-11-09: someone who keeps another desktop app
// should still want cmux running, as "a good transport between everybody".
import { useCallback, useId, useRef, useState } from "react";
import { Button } from "../../../ui/Button";
import { agentDisplayName } from "../../../agent-session/acpmux/agents";
import { AgentMark } from "../../../agent-session/shared/AgentMark";
import { useStore } from "../context";
import type { IntegrationRow, IntegrationsRun, IntegrationsState } from "../ops";
import { t } from "../strings";

type Gesture = Exclude<IntegrationsRun["action"], "refresh">;

/** The id prefix of a link row (cmux-tui agent_hook_links.rs). */
const LINK = "link-";

/** A link row's app (`claude-desktop`, `claude-code`, `codex`), or null for a hook row. */
export function linkApp(id: string): string | null {
  return id.startsWith(LINK) ? id.slice(LINK.length) : null;
}

/** A link row's name: the app's own name, untranslated, and Codex's with both of its surfaces. */
function linkTitle(app: string): string {
  switch (app) {
    case "claude-desktop":
      return "Claude desktop";
    case "claude-code":
      return "Claude Code";
    case "codex":
      return t("settingsWindow.agentIntegrations.links.app.codex");
    default:
      return app;
  }
}

/** The words of a gesture: Connect, Reconnect and Disconnect for a link row. */
function gestureLabel(gesture: Gesture, link: boolean): string {
  if (!link) return t(`settingsWindow.agentIntegrations.${gesture}`);
  const word = gesture === "install" ? "connect" : gesture === "repair" ? "reconnect" : "disconnect";
  return t(`settingsWindow.agentIntegrations.links.${word}`);
}

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
  const app = linkApp(row.id);
  const link = app !== null;
  const blocked = row.state === "conflict" || row.state === "unavailable";
  const manual = `${command} ${row.id}`;
  const stateKey = link ? "links.state" : "state";
  return (
    <div className="row accounts-row" data-integration={row.id} data-integration-state={row.state}>
      <div className="row-main">
        <span className="accounts-mark" aria-hidden="true">
          <AgentMark agent={app ? (app.startsWith("claude") ? "claude" : "codex") : row.id} size={16} />
        </span>
        <div className="row-label">
          <div className="row-title" id={titleId}>
            {app ? linkTitle(app) : agentDisplayName(row.id)}
          </div>
          {row.path && <div className="row-help selectable font-mono">{row.path}</div>}
          {blocked && link && (
            <div className="row-help" data-integration-reason={row.reason ?? "unreadable"}>
              {t(`settingsWindow.agentIntegrations.links.${row.state === "conflict" ? "conflict" : "unreadable"}`)}
            </div>
          )}
          {blocked && !link && (
            <div className="row-help" data-integration-reason={row.reason ?? "unreadable"}>
              {t(`settingsWindow.agentIntegrations.conflict.${row.reason ?? "unreadable"}`)}
            </div>
          )}
          {blocked && !link && row.state === "conflict" && (
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
            {t(`settingsWindow.agentIntegrations.${stateKey}.${row.state}`)}
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
              {gestureLabel(gesture, link)}
            </Button>
          ))}
          {row.state === "conflict" && !link && (
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
  const providers = state?.providers ?? [];
  const links = providers.filter((entry) => linkApp(entry.id) !== null);
  const hooks = providers.filter((entry) => linkApp(entry.id) === null);
  const row = (entry: IntegrationRow) => (
    <Row
      key={entry.id}
      row={entry}
      command={command}
      busy={busy !== null}
      onRun={(gesture) => void run(entry.id, gesture)}
      onCopy={(text) => void store.copy(text)}
    />
  );
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
        {links.length > 0 && (
          <div className="rows" data-integrations-links="">
            <div className="row-title" role="heading" aria-level={3}>
              {t("settingsWindow.agentIntegrations.links.title")}
            </div>
            <div className="row-help">{t("settingsWindow.agentIntegrations.links.help")}</div>
            {links.map(row)}
            <div className="row-help">{t("settingsWindow.agentIntegrations.links.restart")}</div>
          </div>
        )}
        {hooks.length > 0 && <div className="rows">{hooks.map(row)}</div>}
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
      </details>
    </section>
  );
}
