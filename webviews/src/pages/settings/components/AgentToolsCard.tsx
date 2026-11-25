// Settings > Agents > Agents on This Mac, under the `agents.cmuxMcp` choice row (on by default): each
// coding agent found on this Mac and whether it gets cmux's MCP server when cmux starts it (its
// terminals and agent chats), read with `cmux setup mcp` (nothing is written). While the row is off,
// Turn On sets it on, only on a click (the host refuses a page script). An agent whose own settings hold a `cmux`
// entry that runs `cmux mcp serve` (used outside cmux; not this build's own manual line) shows a
// notice with the exact line that removes it and a Remove button: only the person's click runs it.
// When cmux keeps the entry (settings it could not put back), the host's `note` says why. Below, the
// manual lines a person runs themselves to use cmux's tools in agents started elsewhere, each with
// Copy: cmux never runs them.
import { useCallback, useRef, useState } from "react";
import { Button } from "../../../ui/Button";
import { AgentMark } from "../../../agent-session/shared/AgentMark";
import { useStore } from "../context";
import type { AgentToolsCardRun, AgentToolsCardState } from "../ops";
import { t } from "../strings";

export function AgentToolsCard() {
  const store = useStore();
  const [state, setState] = useState<AgentToolsCardState | null>(null);
  const [busy, setBusy] = useState(false);
  // One read when the card first mounts (it writes nothing).
  const read = useRef(false);
  const mounted = useCallback(
    (node: HTMLElement | null) => {
      if (!node || read.current) return;
      read.current = true;
      void store.runAgentTools({ action: "refresh" }).then(setState);
    },
    [store],
  );
  const run = (gesture: AgentToolsCardRun) => {
    setBusy(true);
    void store
      .runAgentTools(gesture)
      .then((next) => {
        if (next) setState(next);
      })
      .finally(() => setBusy(false));
  };
  const rows = state?.rows ?? [];
  const manual = state?.manual ?? [];
  const on = state?.choice !== "off";
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
                  {row.leftover && (
                    <>
                      <div className="row-help" data-agent-tools-leftover="">
                        {t("settingsWindow.agentTools.leftover")}
                      </div>
                      {/* The line Remove runs, to read or run by hand: a value, not a description. */}
                      <div className="row-help selectable">
                        <code className="font-mono" data-agent-tools-leftover-line="">
                          {row.leftover}
                        </code>
                      </div>
                    </>
                  )}
                </div>
                <div className="row-control">
                  {row.leftover && (
                    <Button
                      type="button"
                      className="button"
                      data-agent-tools-action="removeLeftover"
                      disabled={working}
                      onClick={() => run({ action: "removeLeftover", id: row.id })}
                    >
                      {t("settingsWindow.agentTools.leftover.remove")}
                    </Button>
                  )}
                  <span className={row.state === "failed" ? "badge badge-warning" : "badge"}>
                    {t(`settingsWindow.agentTools.state.${row.state}`)}
                  </span>
                </div>
              </div>
            </div>
          ))}
        </div>
      )}
      {state?.failed && <div className="row-error">{t("settingsWindow.agentTools.failed")}</div>}
      {state?.note && (
        <div className="row-error" data-agent-tools-note="">
          {state.note}
        </div>
      )}
      {!on && (
        <div className="accounts-header">
          <Button
            type="button"
            className="button"
            data-agent-tools-action="turnOn"
            disabled={working || state === null}
            onClick={() => run({ action: "turnOn" })}
          >
            {t("settingsWindow.agentTools.add")}
          </Button>
        </div>
      )}
      {manual.length > 0 && (
        <div className="rows" data-agent-tools-manual="">
          <div className="row-title">{t("settingsWindow.agentTools.manual.title")}</div>
          <div className="row-help">{t("settingsWindow.agentTools.manual.help")}</div>
          {manual.map((line) => (
            <div key={line} className="row">
              <div className="row-main">
                <div className="row-label row-help selectable">
                  <code className="font-mono" data-agent-tools-manual-line="">
                    {line}
                  </code>
                </div>
                <div className="row-control">
                  <Button
                    type="button"
                    className="button"
                    data-agent-tools-action="copy"
                    onClick={() => void store.copy(line)}
                  >
                    {t("settingsWindow.agentTools.manual.copy")}
                  </Button>
                </div>
              </div>
            </div>
          ))}
        </div>
      )}
    </section>
  );
}
