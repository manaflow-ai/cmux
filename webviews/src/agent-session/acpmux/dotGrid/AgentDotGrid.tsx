import { useT } from "../i18n";
import { sessionTitle, type AcpmuxSessionEntry } from "../sessionList";
import { agentDots, DOT_LABELS, DOT_STATES, dotCounts } from "./dotGridModel";
import "./agentDotGrid.css";

/// Every agent chat as one dot (the agent-dot-grid experiment): fill and outline carry the state, a
/// running dot pulses, a state change fades its colors. Hover names the chat; a click opens it.
/// Renders nothing when there is no listed chat.
export function AgentDotGrid({
  sessions,
  currentId,
  onSelect,
  size = "regular",
  legend = false,
}: {
  sessions: readonly AcpmuxSessionEntry[];
  /// The chat this pane shows: its dot is ringed, not hidden, so the grid counts every chat.
  currentId?: string;
  onSelect: (sessionId: string) => void;
  size?: "regular" | "compact";
  /// A key of the five states under the grid, each with its count.
  legend?: boolean;
}) {
  const t = useT();
  const dots = agentDots(sessions, (session) => sessionTitle(session, t));
  if (dots.length === 0) return null;
  const counts = dotCounts(dots);
  return (
    <section className="acpmux-dot-grid" data-size={size} aria-label={t("dotGrid.label", { count: dots.length })}>
      <ul className="acpmux-dot-grid__field">
        {dots.map((dot) => {
          const label = `${dot.title} · ${t(DOT_LABELS[dot.state])}`;
          return (
            <li key={dot.sessionId} className="acpmux-dot-grid__cell">
              <button
                type="button"
                className="acpmux-dot-grid__dot"
                data-state={dot.state}
                data-current={dot.sessionId === currentId || undefined}
                title={label}
                aria-label={label}
                onClick={() => onSelect(dot.sessionId)}
              />
            </li>
          );
        })}
      </ul>
      {legend && (
        <ul className="acpmux-dot-grid__legend">
          {DOT_STATES.map((state) => (
            <li key={state} className="acpmux-dot-grid__key">
              <span className="acpmux-dot-grid__dot" data-state={state} aria-hidden="true" />
              <span>{t(DOT_LABELS[state])}</span>
              <span className="acpmux-dot-grid__count">{counts[state]}</span>
            </li>
          ))}
        </ul>
      )}
    </section>
  );
}
