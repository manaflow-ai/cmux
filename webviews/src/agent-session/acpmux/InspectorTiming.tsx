// The inspector's Timing tab: where each turn's wait went between the message and the agent's first
// output, as acpmux recorded it (`_acpmux/history`, acpmux hub/history_timing.rs). Three
// contiguous phases per turn: the message to the prompt written to the agent (`toAgentMs`), the
// prompt held behind the agent's work or a compaction (`queuedMs`, `queuedOn`), and from there to
// the first output (`firstModelMs`). Turns sit on one session axis, so idle time between them stays
// visible. Only recorded values show: a missing stamp says unknown, a measured zero stays zero, and
// no client clock runs for an open turn. It reads once when the tab opens (Refresh reads again).
import { useEffect, useRef, useState, type CSSProperties } from "react";
import { useT } from "./i18n";
import { clockTime } from "./inspectorModel";
import { spanTime } from "./conversation/turnWaterfallModel";
import "./InspectorTiming.css";

export type InspectorTurn = {
  seq: number;
  startedAt: number;
  endedAt?: number | null;
  wallMs?: number | null;
  toAgentMs?: number | null;
  queuedMs?: number | null;
  queuedOn?: "busy" | "compacting" | null;
  firstModelMs?: number | null;
  prompt: string;
  status: string;
};

export type InspectorHistory = { sessionId: string; turns: InspectorTurn[] };
export type ReadInspectorHistory = (sessionId: string) => Promise<InspectorHistory>;

type Phase = { kind: "send" | "queued" | "model"; at: number; ms: number };

/** A turn's recorded phases, end to end from its message; a phase after a missing one is not placed. */
export function turnPhases(turn: InspectorTurn): Phase[] {
  const phases: Phase[] = [];
  if (turn.toAgentMs == null) return phases;
  let at = turn.startedAt;
  phases.push({ kind: "send", at, ms: turn.toAgentMs });
  at += turn.toAgentMs;
  if (turn.firstModelMs == null) return phases;
  const queued = turn.queuedMs ?? 0;
  if (queued > 0) phases.push({ kind: "queued", at, ms: queued });
  phases.push({ kind: "model", at: at + queued, ms: turn.firstModelMs });
  return phases;
}

/** The message to the first output, when every phase was recorded. */
export function toFirstOutputMs(turn: InspectorTurn): number | undefined {
  if (turn.toAgentMs == null || turn.firstModelMs == null) return undefined;
  return turn.toAgentMs + (turn.queuedMs ?? 0) + turn.firstModelMs;
}

export function InspectorTiming({ sessionId, read }: { sessionId: string; read: ReadInspectorHistory }) {
  const t = useT();
  const [history, setHistory] = useState<InspectorHistory>();
  const [error, setError] = useState<string>();
  const [reads, setReads] = useState(0);
  // The reader may be a new function each render; the read follows the session and Refresh only.
  const readRef = useRef(read);
  readRef.current = read;
  useEffect(() => {
    let active = true;
    setError(undefined);
    void readRef
      .current(sessionId)
      .then((value) => {
        // A late answer for another chat never replaces the selected one.
        if (active && value.sessionId === sessionId) setHistory(value);
      })
      .catch((reason: unknown) => {
        if (active) setError(reason instanceof Error ? reason.message : String(reason));
      });
    return () => {
      active = false;
    };
  }, [sessionId, reads]);
  return (
    <div className="acpmux-timing-host">
      <div className="acpmux-inspector-tools">
        <span className="acpmux-inspector-count">{t("inspector.recordedOnly")}</span>
        <button type="button" onClick={() => setReads((n) => n + 1)}>
          {t("git.refresh")}
        </button>
      </div>
      {error ? (
        <p role="alert" className="acpmux-timing-note">
          {error}
        </p>
      ) : history?.sessionId === sessionId ? (
        <SessionTiming turns={history.turns} />
      ) : (
        <output className="acpmux-timing-note">{t("inspector.unknown")}</output>
      )}
    </div>
  );
}

export function SessionTiming({
  turns,
  look = "bars",
}: {
  turns: readonly InspectorTurn[];
  look?: "bars" | "compact" | "stacked";
}) {
  const t = useT();
  if (!turns.length) {
    return (
      <section className={`acpmux-timing is-${look}`} aria-label={t("inspector.timing")}>
        <p className="acpmux-timing-note">{t("inspector.none")}</p>
      </section>
    );
  }
  // Geometry only; the daemon owns every duration.
  const start = Math.min(...turns.map((turn) => turn.startedAt));
  const end = Math.max(
    ...turns.map((turn) => {
      const phases = turnPhases(turn);
      const last = phases[phases.length - 1];
      return Math.max(turn.endedAt ?? turn.startedAt, last ? last.at + last.ms : turn.startedAt);
    }),
  );
  const total = Math.max(1, end - start);
  const place = (at: number, ms: number): CSSProperties =>
    ({
      "--timing-from": `${Math.max(0, ((at - start) / total) * 100)}%`,
      "--timing-width": `${(Math.max(0, Math.min(ms, end - at)) / total) * 100}%`,
    }) as CSSProperties;
  const time = (ms: number | null | undefined) => (ms == null ? t("inspector.unknown") : spanTime(t, ms));
  const phaseLabel = (turn: InspectorTurn, kind: Phase["kind"]) =>
    kind === "send"
      ? t("inspector.sendDelay")
      : kind === "model"
        ? t("inspector.firstOutput")
        : turn.queuedOn === "compacting"
          ? t("inspector.queuedCompacting")
          : t("inspector.queued");
  return (
    <section className={`acpmux-timing is-${look}`} aria-label={t("inspector.timing")}>
      <div className="acpmux-timing-axis">
        <time>{clockTime(start)}</time>
        <time>{clockTime(end)}</time>
      </div>
      <ol className="acpmux-timing-turns">
        {turns.map((turn) => {
          const phases = turnPhases(turn);
          return (
            <li key={turn.seq}>
              <details>
                <summary>
                  <span className="acpmux-timing-prompt">{turn.prompt || t("inspector.session")}</span>
                  <span className="acpmux-timing-total" title={t("inspector.toFirstOutput")}>
                    {time(toFirstOutputMs(turn))}
                  </span>
                  <span className="acpmux-timing-total">{time(turn.wallMs)}</span>
                </summary>
                <dl className="acpmux-inspector-state">
                  <div>
                    <dt>{t("inspector.sendDelay")}</dt>
                    <dd>{time(turn.toAgentMs)}</dd>
                  </div>
                  {(turn.queuedMs ?? 0) > 0 && (
                    <div>
                      <dt>{phaseLabel(turn, "queued")}</dt>
                      <dd>{time(turn.queuedMs)}</dd>
                    </div>
                  )}
                  <div>
                    <dt>{t("inspector.firstOutput")}</dt>
                    <dd>{time(turn.firstModelMs)}</dd>
                  </div>
                  <div>
                    <dt>{t("inspector.toFirstOutput")}</dt>
                    <dd>{time(toFirstOutputMs(turn))}</dd>
                  </div>
                </dl>
              </details>
              <div className="acpmux-timing-track" title={`${clockTime(turn.startedAt)} · ${time(turn.wallMs)}`}>
                {turn.wallMs != null && (
                  <span className="acpmux-timing-bar" style={place(turn.startedAt, turn.wallMs)} />
                )}
              </div>
              <div className="acpmux-timing-track is-phases">
                {phases.map((phase) => (
                  <span
                    key={phase.kind}
                    className={`acpmux-timing-bar is-${phase.kind}`}
                    style={place(phase.at, phase.ms)}
                    title={`${phaseLabel(turn, phase.kind)} · ${time(phase.ms)}`}
                  />
                ))}
              </div>
            </li>
          );
        })}
      </ol>
    </section>
  );
}
