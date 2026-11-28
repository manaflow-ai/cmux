import { Term } from "./Term";
import { formatBytes, formatMs, turnLabel } from "./model";
import type { Status } from "./types";

/** The brain host now: settle progress, the running turn, compactor work, failures. */
export function LiveView({ status }: { status?: Status }) {
  if (!status) return <p className="muted">Loading…</p>;
  const settle = status.settle;
  return (
    <section className="live" aria-label="Live">
      <div className="card">
        <h3>
          <Term id="settle">Settle</Term>
        </h3>
        {settle ? (
          <>
            <progress max={settle.total} value={settle.built} aria-label="Settle progress" />
            <p>
              A turn waits: {settle.built} of {settle.total} view lines summarized.
            </p>
          </>
        ) : status.settled ? (
          <p>Settled: every view line is a summary, so a turn can start at once.</p>
        ) : (
          <p>{status.unbuilt} view lines are not summarized yet (no turn is waiting).</p>
        )}
      </div>
      <div className="card">
        <h3>
          <Term id="turn">Turn</Term>
        </h3>
        {status.running_turn ? (
          <p>
            Running: {turnLabel(status.running_turn)} on {status.running_turn.harness ?? "?"}, started{" "}
            {formatMs(Date.now() - status.running_turn.ts)} ago.
          </p>
        ) : (
          <p>No turn is running.</p>
        )}
        {status.last_turn && (
          <p className="muted">
            Last: {turnLabel(status.last_turn)}, {status.last_turn.status}, {formatMs(status.last_turn.ms)}.
          </p>
        )}
      </div>
      <div className="card">
        <h3>
          <Term id="compactor">Compactor</Term>
        </h3>
        <p>{status.busy.length ? `Writing ${status.busy.length} summaries: ${status.busy.join(", ")}` : "Idle."}</p>
        {status.failures.length > 0 && (
          <ul className="error">
            {status.failures.map((f) => (
              <li key={f.node}>
                {f.node}: {f.error}
              </li>
            ))}
          </ul>
        )}
      </div>
      <div className="card">
        <h3>Memory</h3>
        <p>
          {status.messages} messages, {status.nodes_built} <Term id="node">nodes</Term> built.{" "}
          <Term id="view">View</Term>: {status.view_lines} lines, {formatBytes(status.view_bytes)} of{" "}
          {formatBytes(status.budget)}.
        </p>
        <progress max={status.budget} value={status.view_bytes} aria-label="View budget used" />
      </div>
      {(status.fatal || status.last_error) && (
        <div className="card">
          <h3>Last error</h3>
          {status.fatal && <p className="error">The memory stopped: {status.fatal}</p>}
          {status.last_error && (
            <p className="error">
              {new Date(status.last_error.ts).toLocaleString()} ({status.last_error.ev}
              {status.last_error.node ? ` ${status.last_error.node}` : ""}): {status.last_error.error}
            </p>
          )}
        </div>
      )}
      {!status.trace_on && <p className="muted">The trace directory is missing, so turns cannot be shown.</p>}
    </section>
  );
}
