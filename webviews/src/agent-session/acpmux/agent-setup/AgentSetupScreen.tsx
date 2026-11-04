import { useEffect, useState } from "react";
import { useEscapeCloses } from "../../../ui/escapeDismiss";
import { Spinner } from "../conversation/icons";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import {
  draftAfterSave,
  parseAgentSetup,
  savedPrompt,
  type AgentSetup,
  type AgentSetupPreset,
  type AgentSetupServer,
} from "./agentSetup";
import "./agentSetup.css";

/// How the cmux additions lay out: one fold per server, closed (`accordions`, the default) or open
/// (`open`), or the servers in a list beside the chosen one's detail (`split`).
export type AgentSetupLayout = "accordions" | "open" | "split";

type Saving = { kind: "saving" } | { kind: "saved" } | { kind: "failed"; reason: string };

/// The Agent setup viewer (Leo, 2026-11-04: "giving the users a better way to, like, see what's
/// actually happening ... as a viewer ... some people just want to edit it a bit"): what the chat's
/// agent is told beside the person's messages, as acpmux reports it (agentSetup.ts). Three parts, top
/// to bottom: the harness's own system prompt (named; it ships inside the harness), the chat's
/// preset's system prompt (editable here where acpmux lets this connection save it), and what cmux
/// adds, one block per MCP server with its instructions in full and its tools.
export function AgentSetupScreen({
  load,
  save,
  openUrl,
  onClose,
  layout = "accordions",
}: {
  /// Reads `_acpmux/agent_setup` for the chat.
  load(): Promise<unknown>;
  /// Sends `_acpmux/agent_setup/save`; without it the preset's prompt is read only.
  save?(systemPrompt: string | null): Promise<unknown>;
  /// Opens a link (the harness's published prompts) in a browser tab.
  openUrl?(url: string): void;
  /// Leaves the viewer; none in the viewer's own tab, which closes with the tab.
  onClose?(): void;
  layout?: AgentSetupLayout;
}) {
  const t = useT();
  const [setup, setSetup] = useState<AgentSetup>();
  const [failed, setFailed] = useState(false);
  const [reads, setReads] = useState(0);
  useEscapeCloses(onClose !== undefined, () => onClose?.());
  useEffect(() => {
    let live = true;
    setFailed(false);
    load()
      .then((reply) => {
        if (!live) return;
        const parsed = parseAgentSetup(reply);
        if (parsed) setSetup(parsed);
        else setFailed(true);
      })
      .catch(() => {
        if (live) setFailed(true);
      });
    return () => {
      live = false;
    };
  }, [load, reads]);
  return (
    <section className="acpmux-agent-setup" aria-label={t("context.setup")} data-layout={layout}>
      <header className="acpmux-agent-setup-head">
        <div className="acpmux-agent-setup-heading">
          <h2>{t("context.setup")}</h2>
          <p>{t("agentSetup.subtitle")}</p>
        </div>
        {onClose && (
          <button
            type="button"
            className="acpmux-agent-setup-close"
            aria-label={t("harnesses.close")}
            onClick={onClose}
          >
            <Icon name="action.close" size={14} />
          </button>
        )}
      </header>
      {!setup && !failed && (
        <div className="acpmux-agent-setup-state" data-agent-setup-state="loading">
          <Spinner size={12} loading />
          {t("agentSetup.loading")}
        </div>
      )}
      {!setup && failed && (
        <div className="acpmux-agent-setup-state" data-agent-setup-state="failed">
          {t("agentSetup.failed")}
          <button type="button" className="acpmux-agent-setup-button" onClick={() => setReads((n) => n + 1)}>
            {t("harnesses.checkAgain")}
          </button>
        </div>
      )}
      {setup && (
        <>
          <section className="acpmux-agent-setup-part" data-agent-setup-part="harness">
            <h3>{t("agentSetup.harnessPrompt")}</h3>
            <div className="acpmux-agent-setup-card">
              <div className="acpmux-agent-setup-source">
                <span className="acpmux-agent-setup-name">{setup.harnessPrompt.source}</span>
                <span className="acpmux-agent-setup-badge">{t("agentSetup.notShown")}</span>
              </div>
              {setup.harnessPrompt.note && <p className="acpmux-agent-setup-note">{setup.harnessPrompt.note}</p>}
              {setup.harnessPrompt.link && openUrl && (
                <button
                  type="button"
                  className="acpmux-agent-setup-link"
                  onClick={() => openUrl(setup.harnessPrompt.link!)}
                >
                  {t("agentSetup.publishedPrompts")}
                  <Icon name="link.external" size={12} />
                </button>
              )}
            </div>
          </section>
          <section className="acpmux-agent-setup-part" data-agent-setup-part="preset">
            <h3>{t("agentSetup.presetPrompt")}</h3>
            {setup.preset ? (
              <PresetPrompt
                // Another preset (never in one chat today) starts the editor over; a save's reply keeps it.
                key={setup.preset.name}
                preset={setup.preset}
                save={
                  save &&
                  (async (text) => {
                    const parsed = parseAgentSetup(await save(text));
                    if (parsed) setSetup(parsed);
                    return parsed?.preset?.systemPrompt;
                  })
                }
              />
            ) : (
              <p className="acpmux-agent-setup-note">{t("agentSetup.noPreset")}</p>
            )}
          </section>
          <section className="acpmux-agent-setup-part" data-agent-setup-part="additions">
            <h3>{t("agentSetup.additions")}</h3>
            {setup.servers.length === 0 ? (
              <p className="acpmux-agent-setup-note">{t("agentSetup.noAdditions")}</p>
            ) : layout === "split" ? (
              <SplitServers servers={setup.servers} />
            ) : (
              <ul className="acpmux-agent-setup-servers">
                {setup.servers.map((server) => (
                  <li key={server.name}>
                    <ServerFold server={server} defaultOpen={layout === "open"} />
                  </li>
                ))}
              </ul>
            )}
          </section>
        </>
      )}
    </section>
  );
}

/// The preset's system prompt: an editor where acpmux lets this connection save it and the harness
/// takes one, else what is known about it and where it can be changed.
function PresetPrompt({
  preset,
  save,
}: {
  preset: AgentSetupPreset;
  /// Answers the prompt acpmux now holds, when its reply says.
  save?: (systemPrompt: string | null) => Promise<string | undefined>;
}) {
  const t = useT();
  const saved = preset.systemPrompt ?? "";
  const [draft, setDraft] = useState(saved);
  const [saving, setSaving] = useState<Saving>();
  if (!preset.takesSystemPrompt)
    return (
      <div className="acpmux-agent-setup-card">
        <span className="acpmux-agent-setup-name">{preset.name}</span>
        <p className="acpmux-agent-setup-note">{t("agentSetup.claudeOnly")}</p>
      </div>
    );
  if ((!preset.editable || !save) && preset.systemPrompt)
    return (
      <div className="acpmux-agent-setup-card" data-agent-setup-read-only>
        <span className="acpmux-agent-setup-name">{preset.name}</span>
        <pre className="acpmux-agent-setup-text">{preset.systemPrompt}</pre>
        <p className="acpmux-agent-setup-note">{t("agentSetup.presetReadOnly")}</p>
      </div>
    );
  if (!preset.editable || !save)
    return (
      <div className="acpmux-agent-setup-card">
        <span className="acpmux-agent-setup-name">{preset.name}</span>
        <p className="acpmux-agent-setup-note">
          {preset.hasSystemPrompt ? t("agentSetup.presetHasPrompt") : t("agentSetup.presetHasNoPrompt")}{" "}
          {t("agentSetup.editOnMac")}
        </p>
      </div>
    );
  const changed = draft !== saved;
  const busy = saving?.kind === "saving";
  const submit = () => {
    setSaving({ kind: "saving" });
    const submitted = draft;
    save(savedPrompt(submitted)).then(
      (stored) => {
        // Text typed while the save was pending stays, unsaved; untouched, the editor shows acpmux's.
        setDraft((current) => draftAfterSave(submitted, current, stored));
        setSaving({ kind: "saved" });
      },
      (error: unknown) =>
        setSaving({ kind: "failed", reason: error instanceof Error && error.message ? error.message : String(error) }),
    );
  };
  return (
    <div className="acpmux-agent-setup-card" data-agent-setup-editor>
      <span className="acpmux-agent-setup-name">{preset.name}</span>
      <textarea
        className="acpmux-agent-setup-editor"
        aria-label={t("agentSetup.presetPrompt")}
        placeholder={t("agentSetup.placeholder")}
        value={draft}
        spellCheck={false}
        rows={8}
        onChange={(event) => {
          setDraft(event.target.value);
          if (saving?.kind !== "saving") setSaving(undefined);
        }}
      />
      <p className="acpmux-agent-setup-note">{t("agentSetup.presetApplies", { name: preset.name })}</p>
      <div className="acpmux-agent-setup-actions">
        {saving?.kind === "failed" && (
          <span
            className="acpmux-agent-setup-status"
            data-status="failed"
            data-agent-setup-save-error
            title={saving.reason}
          >
            {t("agentSetup.saveFailed", { reason: saving.reason })}
          </span>
        )}
        {saving?.kind === "saved" && !changed && (
          <span className="acpmux-agent-setup-status">{t("agentSetup.saved")}</span>
        )}
        <button
          type="button"
          className="acpmux-agent-setup-button"
          disabled={!changed || busy}
          onClick={() => {
            setDraft(saved);
            setSaving(undefined);
          }}
        >
          {t("agentSetup.revert")}
        </button>
        <button
          type="button"
          className="acpmux-agent-setup-button is-primary"
          data-agent-setup-save
          disabled={!changed || busy}
          onClick={submit}
        >
          {busy ? t("agentSetup.saving") : t("agentSetup.save")}
        </button>
      </div>
    </div>
  );
}

/// One server's instructions in full, then its tools.
function ServerBody({ server }: { server: AgentSetupServer }) {
  const t = useT();
  const [toolsOpen, setToolsOpen] = useState(false);
  return (
    <div className="acpmux-agent-setup-server-body">
      {server.instructions ? (
        <pre className="acpmux-agent-setup-text">{server.instructions}</pre>
      ) : (
        <p className="acpmux-agent-setup-note">{t("agentSetup.noInstructions")}</p>
      )}
      {server.tools.length > 0 && (
        <div className="acpmux-agent-setup-tools">
          <button
            type="button"
            className="acpmux-agent-setup-fold"
            aria-expanded={toolsOpen}
            onClick={() => setToolsOpen((open) => !open)}
          >
            <Icon name={toolsOpen ? "disclosure.expanded" : "disclosure.collapsed"} size={12} />
            {t("agentSetup.tools", { count: server.tools.length })}
          </button>
          {toolsOpen && (
            <ul className="acpmux-agent-setup-tool-list">
              {server.tools.map((tool) => (
                <li key={tool.name}>
                  <code className="acpmux-agent-setup-tool-name">{tool.name}</code>
                  {tool.description && <span className="acpmux-agent-setup-tool-detail">{tool.description}</span>}
                </li>
              ))}
            </ul>
          )}
        </div>
      )}
    </div>
  );
}

const emptyServer = (server: AgentSetupServer) => !server.instructions && server.tools.length === 0;

/// A server as a fold titled with its name; one with nothing to show is its name alone.
function ServerFold({ server, defaultOpen }: { server: AgentSetupServer; defaultOpen: boolean }) {
  const t = useT();
  const [open, setOpen] = useState(defaultOpen);
  if (emptyServer(server))
    return (
      <div className="acpmux-agent-setup-server" data-agent-setup-server={server.name} data-empty="">
        <span className="acpmux-agent-setup-server-title">
          <span className="acpmux-agent-setup-name">{server.name}</span>
          <span className="acpmux-agent-setup-count">{t("agentSetup.noInstructions")}</span>
        </span>
      </div>
    );
  return (
    <div className="acpmux-agent-setup-server" data-agent-setup-server={server.name} data-open={open ? "" : undefined}>
      <button
        type="button"
        className="acpmux-agent-setup-server-title"
        aria-expanded={open}
        onClick={() => setOpen((was) => !was)}
      >
        <Icon name={open ? "disclosure.expanded" : "disclosure.collapsed"} size={12} />
        <span className="acpmux-agent-setup-name">{server.name}</span>
        {server.tools.length > 0 && (
          <span className="acpmux-agent-setup-count">{t("agentSetup.tools", { count: server.tools.length })}</span>
        )}
      </button>
      {open && <ServerBody server={server} />}
    </div>
  );
}

/// The servers in a list beside the chosen one's instructions and tools.
function SplitServers({ servers }: { servers: AgentSetupServer[] }) {
  const t = useT();
  const [chosen, setChosen] = useState(servers[0]?.name);
  const shown = servers.find((server) => server.name === chosen) ?? servers[0];
  return (
    <div className="acpmux-agent-setup-split">
      <ul className="acpmux-agent-setup-split-list" aria-label={t("agentSetup.additions")}>
        {servers.map((server) => (
          <li key={server.name}>
            <button
              type="button"
              aria-pressed={server === shown}
              data-agent-setup-server={server.name}
              onClick={() => setChosen(server.name)}
            >
              <span className="acpmux-agent-setup-name">{server.name}</span>
              <span className="acpmux-agent-setup-count">
                {emptyServer(server)
                  ? t("agentSetup.noInstructions")
                  : t("agentSetup.tools", { count: server.tools.length })}
              </span>
            </button>
          </li>
        ))}
      </ul>
      {shown && (
        <div className="acpmux-agent-setup-split-detail">
          <ServerBody key={shown.name} server={shown} />
        </div>
      )}
    </div>
  );
}
