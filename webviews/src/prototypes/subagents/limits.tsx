// l10n-allow-file: gallery prototype (sample labels), not shipped UI.
// Limits of a session's subagents: how many children one agent may start (width, default 50) and
// how deep the family may go (depth, default 10). The header line shows the use against the limit;
// the panel raises it for this session; the settings group holds the defaults for new sessions.
import { useState } from "react";
import { DEFAULT_LIMITS, type AgentNode, type Limits } from "./hierarchy";
import type { Platform } from "./parts";

/** "38 of 50 · depth 4 of 10", with the over-limit part named. */
export function LimitLine({
  used,
  depth,
  limits,
  refused,
  onOpen,
  open,
}: {
  used: number;
  depth: number;
  limits: Limits;
  refused: number;
  onOpen: () => void;
  open: boolean;
}) {
  const near = used >= limits.width * 0.9 || depth >= limits.depth - 1;
  return (
    <div className="sa-limit-line" data-near={near || undefined}>
      <span>
        {Math.min(used, limits.width)} of {limits.width} subagents · depth {depth} of {limits.depth}
        {refused > 0 && <strong> · {refused} starts refused</strong>}
      </span>
      <button type="button" className="sa-text-button" aria-expanded={open} onClick={onOpen}>
        Limits
      </button>
    </div>
  );
}

function Stepper({
  label,
  value,
  step,
  min,
  max,
  onChange,
}: {
  label: string;
  value: number;
  step: number;
  min: number;
  max: number;
  onChange: (value: number) => void;
}) {
  return (
    <div className="sa-stepper">
      <span className="sa-stepper-label">{label}</span>
      <span className="sa-stepper-controls">
        <button type="button" aria-label={`Lower ${label}`} disabled={value <= min} onClick={() => onChange(Math.max(min, value - step))}>
          −
        </button>
        <output aria-live="polite">{value}</output>
        <button type="button" aria-label={`Raise ${label}`} disabled={value >= max} onClick={() => onChange(Math.min(max, value + step))}>
          +
        </button>
      </span>
    </div>
  );
}

/** The panel under the header: raise this session's limits. */
const SOURCE_LABEL: Record<AgentNode["limitsSource"], string> = {
  session: "set on this session",
  inherited: "from a parent session",
  settings: "from Settings",
  default: "the default",
};

/** The panel under the header: raise this session's limits (the person path, `_acpmux/subsession/limits`). */
export function LimitsPanel({ session, platform, finished }: { session: AgentNode; platform: Platform; finished: number }) {
  const [limits, setLimits] = useState(session.limits);
  const changed = limits.width !== session.limits.width || limits.depth !== session.limits.depth;
  return (
    <section className="sa-limits-panel" data-platform={platform} aria-label="Subagent limits">
      <h3>Limits for “{session.name}”</h3>
      <p className="sa-muted">
        Agents in this session can start subagents up to these limits ({SOURCE_LABEL[session.limitsSource]}). Past a
        limit the start is refused and the agent is told why. A closed subagent frees its slot.
      </p>
      <Stepper
        label="Subagents per agent"
        value={limits.width}
        step={10}
        min={1}
        max={500}
        onChange={(width) => setLimits({ ...limits, width })}
      />
      <Stepper label="Depth" value={limits.depth} step={1} min={1} max={50} onChange={(depth) => setLimits({ ...limits, depth })} />
      <div className="sa-limits-actions">
        <button type="button" className="sa-text-button" onClick={() => setLimits({ width: limits.width * 2, depth: limits.depth })}>
          Double subagents
        </button>
        {finished > 0 && (
          <button type="button" className="sa-text-button">
            Close {finished} finished
          </button>
        )}
        <span className="sa-spacer" />
        <button type="button" className="sa-button" disabled={!changed} onClick={() => setLimits(session.limits)}>
          Reset
        </button>
        <button type="button" className="sa-button sa-button-primary" disabled={!changed}>
          Apply
        </button>
      </div>
      <p className="sa-muted sa-small">
        This session and its subagents. New sessions use {DEFAULT_LIMITS.width} and {DEFAULT_LIMITS.depth} (Settings ›
        Agents › Subagents). The ceiling is 1000 and 100.
      </p>
    </section>
  );
}

/** Settings › Agents › Subagents: the defaults for new sessions. */
export function LimitsSettings({ platform }: { platform: Platform }) {
  const [width, setWidth] = useState(DEFAULT_LIMITS.width);
  const [depth, setDepth] = useState(DEFAULT_LIMITS.depth);
  const [enabled, setEnabled] = useState(true);
  return (
    <section className="sa-settings" data-platform={platform} aria-label="Subagent settings">
      <h2>Subagents</h2>
      <p className="sa-muted">Agents can start subagents, which can start their own. These limits apply to every new session.</p>
      <div className="sa-settings-group">
        <Stepper label="Subagents per agent" value={width} step={10} min={1} max={500} onChange={setWidth} />
        <Stepper label="Depth" value={depth} step={1} min={1} max={50} onChange={setDepth} />
      </div>
      <div className="sa-settings-group">
        <label className="sa-radio">
          <input type="checkbox" checked={enabled} onChange={(event) => setEnabled(event.target.checked)} />
          Agents can start subagents
        </label>
      </div>
      <p className="sa-muted sa-small">
        Past a limit the start is refused and the agent is told how to get more: close a finished subagent, or ask you to
        raise the session’s limit. Changes apply at once.
      </p>
    </section>
  );
}
