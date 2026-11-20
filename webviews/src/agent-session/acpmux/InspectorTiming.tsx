// The inspector reads the daemon's journal-derived timings only while open. This is a
// trace in wall-clock order: idle gaps remain visible, and missing stamps stay unknown.
import { useEffect, useState, type CSSProperties } from "react";
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
  firstModelMs?: number | null;
  prompt: string;
  status: string;
};

export type InspectorHistory = { sessionId: string; turns: InspectorTurn[] };

export function InspectorTiming({
  sessionId,
  read,
}: {
  sessionId: string;
  read: (sessionId: string) => Promise<InspectorHistory>;
}) {
  const t = useT();
  const [history, setHistory] = useState<InspectorHistory>();
  const [error, setError] = useState<string>();
  useEffect(() => {
    let active = true;
    void read(sessionId)
      .then((value) => {
        if (value.sessionId !== sessionId) throw new Error(t("inspector.unknown"));
        if (active) setHistory(value);
      })
      .catch((reason: unknown) => {
        if (active) setError(reason instanceof Error ? reason.message : String(reason));
      });
    return () => {
      active = false;
    };
  }, [read, sessionId, t]);
  if (error) return <p role="alert">{error}</p>;
  if (!history) return <output>{t("inspector.unknown")}</output>;
  return <SessionFlameGraph turns={history.turns} />;
}

export function SessionFlameGraph({
  turns,
  look = "bars",
}: {
  turns: readonly InspectorTurn[];
  look?: "bars" | "compact" | "stacked";
}) {
  const t = useT();
  // Geometry only; the daemon owns all durations. Never run a client clock for an open turn.
  const start = Math.min(...turns.map((turn) => turn.startedAt));
  const end = Math.max(
    ...turns.map((turn) => turn.endedAt ?? turn.startedAt + (turn.toAgentMs ?? 0) + (turn.firstModelMs ?? 0)),
  );
  const total = Math.max(1, end - start);
  const place = (at: number, duration: number): CSSProperties =>
    ({
      "--timing-from": `${Math.max(0, ((at - start) / total) * 100)}%`,
      "--timing-width": `${(Math.max(0, Math.min(duration, end - at)) / total) * 100}%`,
    }) as CSSProperties;
  const time = (ms: number | null | undefined) => (ms == null ? t("inspector.unknown") : spanTime(t, ms));
  return (
    <section className={`acpmux-timing is-${look}`} aria-label={t("inspector.timing")}>
      <p className="acpmux-timing-note">{t("inspector.recordedOnly")}</p>
      {turns.length > 0 && (
        <div className="acpmux-timing-axis">
          <time>{clockTime(start)}</time>
          <time>{clockTime(end)}</time>
        </div>
      )}
      {!turns.length && <p>{t("inspector.none")}</p>}
      <ol className="acpmux-timing-turns">
        {turns.map((turn) => (
          <li key={turn.seq}>
            <details>
              <summary>
                <span className="acpmux-timing-prompt">{turn.prompt || t("inspector.session")}</span>
                <span>{time(turn.wallMs)}</span>
              </summary>
              <dl className="acpmux-inspector-state">
                <div>
                  <dt>{t("inspector.sendDelay")}</dt>
                  <dd>{time(turn.toAgentMs)}</dd>
                </div>
                <div>
                  <dt>{t("inspector.firstOutput")}</dt>
                  <dd>{time(turn.firstModelMs)}</dd>
                </div>
              </dl>
            </details>
            <div className="acpmux-timing-track" title={`${clockTime(turn.startedAt)} · ${time(turn.wallMs)}`}>
              {turn.wallMs != null && <span className="acpmux-timing-bar" style={place(turn.startedAt, turn.wallMs)} />}
            </div>
            <div className="acpmux-timing-track is-phases">
              {turn.toAgentMs != null && (
                <span
                  className="acpmux-timing-bar is-send"
                  style={place(turn.startedAt, turn.toAgentMs)}
                  title={`${t("inspector.sendDelay")} · ${time(turn.toAgentMs)}`}
                />
              )}
              {turn.toAgentMs != null && turn.firstModelMs != null && (
                <span
                  className="acpmux-timing-bar is-model"
                  style={place(turn.startedAt + turn.toAgentMs, turn.firstModelMs)}
                  title={`${t("inspector.firstOutput")} · ${time(turn.firstModelMs)}`}
                />
              )}
            </div>
          </li>
        ))}
      </ol>
    </section>
  );
}
