// "Thinking 4s": a running turn before its first output, with the time since the prompt (`since`),
// ticking each second, so a long first think never reads as a stuck label. No mark blinks before it
// (Leo, 2026-10-20: "wtf have we removed this yet"); the word itself carries the motion, as the Codex
// and ChatGPT apps draw it: a light band in the theme accent sweeps across it (`is-shimmer`,
// conversation.css), still under Reduce Motion and the static status look. Before the turn, while
// the prompt waits for its agent to start, the same line reads the start status ("Starting Claude
// Code…") with Cancel, no time and no sweep, so the line keeps one place from send to the first
// output (cx-ncc.58). Only the status is the live region.
import { useEffect, useState } from "react";
import { useT } from "../i18n";
import { formatDuration } from "./turns";
import { useTicking } from "./WorkingFor";

/// How long streaming text must hold still before the live line comes back under it.
export const QUIET_MS = 1200;

/// False while `key` changed in the last `ms`, true once it held still that long (or there is none).
function useQuiet(key: string | undefined, ms = QUIET_MS): boolean {
  const [quiet, setQuiet] = useState(key === undefined);
  useEffect(() => {
    if (key === undefined) {
      setQuiet(true);
      return;
    }
    setQuiet(false);
    const timer = setTimeout(() => setQuiet(true), ms);
    return () => clearTimeout(timer);
  }, [key, ms]);
  return quiet;
}

/// `doing`, `doingAt`, `doingShell`, `untimed`, `quietKey`: the Codex-style live line at the bottom
/// of a running turn (conversation/turns.ts `codexLiveTurn`), which each step replaces in place:
/// "Thinking", or the call in flight ("Running bun test 13s", or what it says it does, "Run the web
/// tests 13s"), its time from the call's start. Both shimmer. While text streams (`quietKey` moves)
/// the line keeps its height but draws nothing.
export function Thinking({
  status,
  onCancel,
  since,
  now = Date.now,
  doing,
  doingAt,
  doingShell = false,
  untimed = false,
  quietKey,
}: {
  status?: string;
  onCancel?: () => void;
  since?: number;
  now?: () => number;
  doing?: string;
  doingAt?: number;
  doingShell?: boolean;
  untimed?: boolean;
  quietKey?: string;
} = {}) {
  const t = useT();
  const from = doing !== undefined ? doingAt : untimed ? undefined : since;
  const timed = !status && from !== undefined;
  const time = useTicking(timed, now);
  const quiet = useQuiet(status || doing !== undefined ? undefined : quietKey);
  const label =
    status ??
    (doing === undefined
      ? t("thinking")
      : doingShell
        ? doing
          ? t("tools.runningCommand", { command: doing })
          : t("tools.runningUnnamed")
        : doing);
  return (
    <div className={quiet ? "cv-worked" : "cv-worked is-quiet"} data-find-skip>
      <output className={status ? "cv-thinking" : "cv-thinking is-shimmer"}>{label}</output>
      {timed && <span className="cv-worked__time">{formatDuration(Math.max(0, time - from))}</span>}
      {status && onCancel && (
        <button type="button" className="cv-thinking__cancel" onClick={onCancel}>
          {t("switch.cancelPrompt")}
        </button>
      )}
    </div>
  );
}
