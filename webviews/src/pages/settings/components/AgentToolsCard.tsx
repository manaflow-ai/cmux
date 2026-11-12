// Settings > Agents > Agents with cmux Tools, under the `agents.cmuxMcp` choice row (the onboarding
// step's question): each coding agent found on this Mac and whether its own config gives it cmux's
// MCP server, read with `cmux setup mcp --dry-run` (nothing is written). Add Now answers yes (the
// choice turns to Add to My Agents) and runs `cmux setup mcp`; Remove runs `cmux setup mcp --remove`,
// which takes out only cmux's own entry. Both run only on a click (the host refuses a page script).
import { useCallback, useRef, useState } from "react";
import { Button } from "../../../ui/Button";
import { AgentMark } from "../../../agent-session/shared/AgentMark";
import { useStore } from "../context";
import type { AgentToolsCardState } from "../ops";
import { t } from "../strings";

export function AgentToolsCard() {
  const store = useStore();
  const [state, setState] = useState<AgentToolsCardState | null>(null);
  const [busy, setBusy] = useState(false);
  // One read when the card first mounts (a dry run: it writes nothing).
  const read = useRef(false);
  const mounted = useCallback(
    (node: HTMLElement | null) => {
      if (!node || read.current) return;
      read.current = true;
      void store.runAgentTools({ action: "refresh" }).then(setState);
    },
    [store],
  );
  const run = async (action: "add" | "remove") => {
    setBusy(true);
    try {
      const next = await store.runAgentTools({ action });
      if (next) setState(next);
    } finally {
      setBusy(false);
    }
  };
  const rows = state?.rows ?? [];
  const added = rows.some((row) => row.state === "added");
  const addable = rows.some((row) => row.state === "ready");
  const working = busy || (state?.applying ?? false);
  return (
    <section className="group" data-card="agentTools" ref={mounted}>
      <div className="group-title">{t("settingsWindow.agentTools.title")}</div>
      <div className="row-help">{t("settingsWindow.agentTools.help")}</div>
      {state === null || !state.loaded ? (
        <div className="row-help" data-agent-tools-checking="">
          {t("settingsWindow.agentTools.checking")}
        </div>
      ) : rows.length === 0 ? (
        <div className="row-help" data-agent-tools-none="">
          {t("settingsWindow.agentTools.none")}
        </div>
      ) : (
        <div className="rows">
          {rows.map((row) => (
            <div key={row.id} className="row accounts-row" data-agent-tools={row.id} data-agent-tools-state={row.state}>
              <div className="row-main">
                <span className="accounts-mark" aria-hidden="true">
                  <AgentMark agent={row.id} size={16} />
                </span>
                <div className="row-label">
                  <div className="row-title">{row.name}</div>
                </div>
                <div className="row-control">
                  <span
                    className={row.state === "failed" || row.state === "conflict" ? "badge badge-warning" : "badge"}
                  >
                    {t(`settingsWindow.agentTools.state.${row.state}`)}
                  </span>
                </div>
              </div>
            </div>
          ))}
        </div>
      )}
      {state?.failed && <div className="row-error">{t("settingsWindow.agentTools.failed")}</div>}
      <div className="accounts-header">
        <Button
          type="button"
          className="button"
          data-agent-tools-action="add"
          disabled={working || !addable}
          onClick={() => void run("add")}
        >
          {t("settingsWindow.agentTools.add")}
        </Button>
        <Button
          type="button"
          className="button"
          data-agent-tools-action="remove"
          disabled={working || !added}
          onClick={() => void run("remove")}
        >
          {t("settingsWindow.agentTools.remove")}
        </Button>
      </div>
    </section>
  );
}
