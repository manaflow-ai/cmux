// Harness updates available (harnessUpdateList.ts): the model menus' update footer, every outdated
// agent CLI on one row each (its mark, its name, the installed and newest versions, Update), Update
// all in the heading once there are two, and the reason under them. The reference (Leo 2026-11-12)
// listed Codex and OpenCode; it is the same list for Claude Code and every other harness.
import type { KeyboardEvent, Ref } from "react";
import { AgentMark } from "../shared/AgentMark";
import { Spinner } from "./conversation/icons";
import { useT } from "./i18n";
import type { HarnessUpdateRow, HarnessUpdates } from "./harnessUpdateList";
import "./harnessUpdates.css";

export function HarnessUpdatesSection({
  updates,
  onOwnUpdate,
  firstAction,
  onFirstKeyDown,
}: {
  updates: HarnessUpdates;
  /// The section's first button (Update all, else the first row's Update), for a menu whose arrows
  /// move from its last model row into the footer (QuickModelColumns).
  firstAction?: Ref<HTMLButtonElement>;
  onFirstKeyDown?: (event: KeyboardEvent<HTMLButtonElement>) => void;
  /// The chat's own agent's Update ran: its progress shows in the composer's notice, so the menu closes.
  onOwnUpdate?: () => void;
}) {
  const t = useT();
  const title = t("harness.updatesAvailable");
  const all = updates.rows.length > 1;
  const run = (row: HarnessUpdateRow) => {
    row.update();
    if (row.skip) onOwnUpdate?.();
  };
  return (
    <section className="acpmux-harness-updates" aria-label={title} data-harness-updates={updates.rows.length}>
      <div className="acpmux-harness-updates-head">
        <span className="acpmux-harness-updates-title">{title}</span>
        {all && (
          <button
            ref={firstAction}
            onKeyDown={onFirstKeyDown}
            type="button"
            className="acpmux-harness-updates-all"
            disabled={updates.rows.every((row) => row.phase === "updating")}
            onClick={() => {
              updates.updateAll();
              if (updates.rows.some((row) => row.skip)) onOwnUpdate?.();
            }}
          >
            {t("harness.updateAll")}
          </button>
        )}
      </div>
      <ul className="acpmux-harness-updates-list">
        {updates.rows.map((row, index) => (
          <li
            key={row.harness}
            className="acpmux-harness-update"
            data-harness-update={row.harness}
            data-phase={row.phase}
          >
            <AgentMark agent={row.harness} size={16} reserve />
            <span className="acpmux-harness-update-name">{row.agent}</span>
            {row.phase === "failed" ? (
              <span className="acpmux-harness-update-versions selectable" title={row.error || undefined}>
                {t("harness.updateFailedShort", { agent: row.agent })}
              </span>
            ) : (
              <span className="acpmux-harness-update-versions">
                {t("harness.versionChange", { version: row.version, latest: row.latest })}
              </span>
            )}
            {row.skip && (
              <button type="button" className="acpmux-harness-update-skip" onClick={row.skip}>
                {t("harness.skipVersion")}
              </button>
            )}
            <button
              {...(!all && index === 0 ? { ref: firstAction, onKeyDown: onFirstKeyDown } : {})}
              type="button"
              className="acpmux-harness-update-run"
              disabled={row.phase === "updating"}
              aria-busy={row.phase === "updating" || undefined}
              onClick={() => run(row)}
            >
              {row.phase === "updating" ? (
                <Spinner size={12} loading />
              ) : row.phase === "failed" ? (
                t("harness.tryAgain")
              ) : (
                t("harness.update")
              )}
            </button>
          </li>
        ))}
      </ul>
      <p className="acpmux-harness-updates-hint">{t("harness.updatesHint")}</p>
    </section>
  );
}
