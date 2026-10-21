// Where a Claude Code chat's session started (sessionStart.ts): one quiet line with what it runs
// on (Claude Code's version, the model, the route to Claude, the folder), then how it compacts,
// until the person dismisses that note. Drawn as a tool row, like a compaction note
// (CompactionNote.tsx), which is how each compaction itself shows later in the chat.
import { useState } from "react";
import { useT } from "../i18n";
import type { AcpmuxSessionStart } from "../model";
import { Close, TerminalSquare } from "./icons";
import {
  compactionModeOf,
  compactionNoticeDismissed,
  dismissCompactionNotice,
  foldHome,
  routeOf,
} from "./sessionStart";

export function SessionStartNote({ start }: { start: AcpmuxSessionStart }) {
  const t = useT();
  const mode = compactionModeOf(start.harness);
  const [dismissed, setDismissed] = useState(() => compactionNoticeDismissed(mode));
  const route = routeOf(start.harness);
  const facts = [
    t("sessionStart.claudeCode", { version: start.version }),
    start.model,
    route === "sr2"
      ? t("sessionStart.route.sr2")
      : route === "coderouter"
        ? t("sessionStart.route.coderouter")
        : t("sessionStart.route.own"),
    start.cwd ? foldHome(start.cwd) : undefined,
  ].filter((fact): fact is string => !!fact);
  return (
    <div className="cv-tools">
      <div className="cv-tool cv-session-start" data-compaction={mode}>
        <span className="cv-tool__icon">
          <TerminalSquare />
        </span>
        <span className="cv-tool__text">{facts.join(" · ")}</span>
      </div>
      {!dismissed && (
        <div className="cv-session-start__compaction" data-compaction={mode}>
          <span className="cv-session-start__compaction-text">
            {mode === "managed" ? t("sessionStart.compaction.managed") : t("sessionStart.compaction.stock")}
          </span>
          <button
            type="button"
            className="cv-session-start__dismiss"
            aria-label={t("sessionStart.compaction.dismiss")}
            title={t("sessionStart.compaction.dismiss")}
            onClick={() => {
              dismissCompactionNotice(mode);
              setDismissed(true);
            }}
          >
            <Close size={12} />
          </button>
        </div>
      )}
    </div>
  );
}
