// Agents > Harnesses (cx-mg91): the coding agents this app's acpmux can start, from the host's
// `cmux.settings.harnesses.state` (it reads acpmux's `_acpmux/harnesses`), live through
// cmux.settings.harnesses.changed. Sign In and Check open a terminal tab of the focused pane
// running `acpmux harness login <id>` (`--status` for Check), so the agent's own sign-in runs
// where the person sees it; Browse ACP Registry runs `acpmux harness registry` the same way.
import { useCallback } from "react";
import { agentDisplayName } from "../../../agent-session/acpmux/agents";
import { AgentMark } from "../../../agent-session/shared/AgentMark";
import { useSettingsState, useStore } from "../context";
import type { HarnessRow } from "../ops";
import { t } from "../strings";

const SOURCES = new Set(["managed", "user-file", "cmux-json", "registry", "path", "config"]);

function sourceText(row: HarnessRow): string {
  return t(`settingsWindow.harnesses.source.${SOURCES.has(row.source) ? row.source : "config"}`);
}

function Row({ row }: { row: HarnessRow }) {
  const store = useStore();
  const name = row.name ?? agentDisplayName(row.id);
  const terminal = row.kind === "terminal";
  return (
    <div className="row accounts-row" tabIndex={-1} data-harness={row.id}>
      <div className="row-main">
        <span className="accounts-mark" aria-hidden="true">
          <AgentMark agent={row.id} size={16} />
        </span>
        <div className="row-label">
          <div className="row-title">{name}</div>
          <div className="row-help">
            {row.id === name.toLowerCase() ? sourceText(row) : `${row.id} · ${sourceText(row)}`}
          </div>
          {row.problem && <div className="row-error">{row.problem}</div>}
        </div>
        <div className="row-control">
          {terminal ? (
            <span className="badge">{t("settingsWindow.harnesses.terminalOnly")}</span>
          ) : (
            <>
              <button
                type="button"
                className="button"
                data-harness-action="check"
                onClick={() => void store.runHarnesses({ action: "check", id: row.id })}
              >
                {t("settingsWindow.harnesses.check")}
              </button>
              <button
                type="button"
                className="button"
                data-harness-action="signIn"
                onClick={() => void store.runHarnesses({ action: "signIn", id: row.id })}
              >
                {t("settingsWindow.harnesses.signIn")}
              </button>
            </>
          )}
        </div>
      </div>
    </div>
  );
}

export function HarnessesCard() {
  const store = useStore();
  const { harnesses } = useSettingsState();
  // Read again when the card mounts (a stable callback ref runs once per mount), like Accounts:
  // a harness installed since the last visit shows.
  const mounted = useCallback(
    (node: HTMLElement | null) => {
      if (node) void store.runHarnesses({ action: "refresh" });
    },
    [store],
  );
  return (
    <section className="group" data-card="harnesses" ref={mounted}>
      <h3 className="group-title">{t("settingsWindow.harnesses.title")}</h3>
      <div className="row-help">{t("settingsWindow.harnesses.help")}</div>
      {harnesses?.problem && (
        <div className="row-error" data-harnesses-problem={harnesses.problem}>
          {t(`settingsWindow.harnesses.problem.${harnesses.problem}`)}
        </div>
      )}
      {harnesses && !harnesses.problem && harnesses.harnesses.length === 0 && !harnesses.loading && (
        <div className="row-help" data-harnesses-empty="">
          {t("settingsWindow.harnesses.empty")}
        </div>
      )}
      <div className="rows">
        {harnesses?.harnesses.map((row) => (
          <Row key={row.id} row={row} />
        ))}
      </div>
      <div className="accounts-buttons">
        <button
          type="button"
          className="button"
          data-harness-action="refresh"
          disabled={harnesses?.loading ?? false}
          onClick={() => void store.runHarnesses({ action: "refresh" })}
        >
          {t("settingsWindow.harnesses.refresh")}
        </button>
        <button
          type="button"
          className="button"
          data-harness-action="registry"
          disabled={harnesses?.problem === "unavailable"}
          onClick={() => void store.runHarnesses({ action: "registry" })}
        >
          {t("settingsWindow.harnesses.registry")}
        </button>
      </div>
    </section>
  );
}
