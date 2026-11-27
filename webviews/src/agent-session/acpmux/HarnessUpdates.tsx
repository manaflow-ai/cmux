// Harness updates available (harnessUpdateList.ts): the model menus' update footer, every outdated
// agent CLI on one row each (its mark, its name, Update), Update all in the heading once there are
// two, and the reason under them. The reference (Leo 2026-11-12) listed Codex and OpenCode; it is
// the same list for Claude Code and every other harness. David Beyer (Nov 20 call) found it messy:
// the versions and Skip This Version show only while Option is held (useOptionHeld.ts), and a
// failed row says so in its name's place, so no row carries more than its name and one action.
// Lawrence (Nov 21): Update all is what most people do, so it is the footer's default button, in the
// accent; a row's Update is a quiet secondary unless it is the only row. The reason ("New models
// often need the latest version.") is the heading's tooltip, not a line of its own.
// a1315 (Lawrence: "drastically simplify all parts of the UI"): one outdated agent is one row, no
// heading; with more, each row's Update shows on the row's hover or focus (data-reveal) beside Update
// all; a failed row is one red line, its mark's space left empty, its Try Again on hover.
import type { KeyboardEvent, Ref } from "react";
import { AgentMark } from "../shared/AgentMark";
import { Spinner } from "./conversation/icons";
import { useT } from "./i18n";
import { useOptionHeld } from "./useOptionHeld";
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
  const detailed = useOptionHeld();
  const run = (row: HarnessUpdateRow) => {
    row.update();
    if (row.skip) onOwnUpdate?.();
  };
  return (
    <section className="acpmux-harness-updates" aria-label={title} data-harness-updates={updates.rows.length}>
      {all && (
        <div className="acpmux-harness-updates-head">
          {/* tooltip-allow: Lawrence 2026-11-21 put the reason in the heading's tooltip, not a line of its own. */}
          <span className="acpmux-harness-updates-title" title={t("harness.updatesHint")}>
            {title}
          </span>
          <button
            ref={firstAction}
            onKeyDown={onFirstKeyDown}
            type="button"
            className="acpmux-harness-updates-all"
            data-default=""
            disabled={updates.rows.every((row) => row.phase === "updating")}
            onClick={() => {
              updates.updateAll();
              if (updates.rows.some((row) => row.skip)) onOwnUpdate?.();
            }}
          >
            {t("harness.updateAll")}
          </button>
        </div>
      )}
      <ul className="acpmux-harness-updates-list">
        {updates.rows.map((row, index) => (
          <li
            key={row.harness}
            className="acpmux-harness-update"
            data-harness-update={row.harness}
            data-phase={row.phase}
          >
            {/* A failed row is its red line alone: the mark's space stays, empty, so names stay aligned. */}
            <AgentMark agent={row.phase === "failed" ? "" : row.harness} size={16} reserve />
            {/* The versions go under the name, so holding Option never cuts the name short. */}
            <span className="acpmux-harness-update-label">
              <span className="acpmux-harness-update-name">
                {row.phase === "failed" ? t("harness.updateFailedShort", { agent: row.agent }) : row.agent}
              </span>
              {detailed && row.phase !== "failed" && (
                <span className="acpmux-harness-update-versions">
                  {t("harness.versionChange", { version: row.version, latest: row.latest })}
                </span>
              )}
            </span>
            {detailed && row.skip && (
              <button type="button" className="acpmux-harness-update-skip" onClick={row.skip}>
                {t("harness.skipVersion")}
              </button>
            )}
            <button
              {...(!all && index === 0 ? { ref: firstAction, onKeyDown: onFirstKeyDown } : {})}
              type="button"
              className="acpmux-harness-update-run"
              {...(!all ? { "data-default": "" } : row.phase === "updating" ? {} : { "data-reveal": "" })}
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
    </section>
  );
}
