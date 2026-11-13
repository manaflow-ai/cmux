// l10n-allow-file: isolated gallery prototype, not shipped UI.
// The three directions for an agent's detail. Same ledger, different first question:
// Ledger asks "what did it build?", Matrix "which states are proven?", Story "why did it go this way?".
import { useState } from "react";
import {
  axesLabel,
  coverage,
  permutationsFor,
  type Board,
  type CapabilityRecord,
  type DecisionRecord,
  type EvidenceRecord,
  orderOf,
} from "./ledger";
import { EvidenceChip, StatusMark, STATUS_LABEL, Thumb, evidenceOf } from "./parts";

type ViewProps = { board: Board; needsYou: boolean; onOpen(evidence: EvidenceRecord): void };

function DecisionCard({ decision, compact }: { decision: DecisionRecord; compact?: boolean }) {
  return (
    <article className={`ab-decision${decision.needsHuman ? " ab-decision-human" : ""}`}>
      <header>
        <h4>{decision.title}</h4>
        {decision.needsHuman && <span className="ab-flag">Needs you</span>}
      </header>
      <p className="ab-chosen">
        <span className="ab-muted">Chose</span> {decision.chosen}
      </p>
      {!compact && decision.why && <p className="ab-why">{decision.why}</p>}
      {decision.rejected?.length ? (
        <ul className="ab-rejected" aria-label="Rejected options">
          {decision.rejected.map((r, i) => (
            <li key={`${i}:${r.option}`}>
              <s>{r.option}</s>
              {r.why && <span className="ab-muted"> — {r.why}</span>}
            </li>
          ))}
        </ul>
      ) : null}
    </article>
  );
}

function CoverageBar({ board, capability }: { board: Board; capability?: CapabilityRecord }) {
  const c = coverage(capability ? permutationsFor(board, capability.id) : board.permutations);
  if (!c.total) return <span className="ab-muted">No states recorded</span>;
  return (
    <span className="ab-coverage" aria-label={`${c.verified} of ${c.total} states verified`}>
      <span className="ab-coverage-track" aria-hidden="true">
        <span className="ab-coverage-ok" style={{ width: `${(c.verified / c.total) * 100}%` }} />
        <span className="ab-coverage-bad" style={{ width: `${(c.broken / c.total) * 100}%` }} />
      </span>
      <span className="ab-coverage-text">
        {c.verified}/{c.total} verified{c.broken ? ` · ${c.broken} broken` : ""}
      </span>
    </span>
  );
}

function visibleCapabilities(board: Board, needsYou: boolean): CapabilityRecord[] {
  if (!needsYou) return board.capabilities;
  return board.capabilities.filter(
    (c) =>
      permutationsFor(board, c.id).some((p) => p.status !== "verified") ||
      board.decisions.some((d) => d.needsHuman && d.for?.includes(c.id)),
  );
}

/** Ledger: a dense list of capabilities, each opening to its states and evidence; decisions in a rail. */
export function LedgerView({ board, needsYou, onOpen }: ViewProps) {
  const caps = visibleCapabilities(board, needsYou);
  const [open, setOpen] = useState<string | null>(caps[0]?.id ?? null);
  const decisions = needsYou ? board.decisions.filter((d) => d.needsHuman) : board.decisions;
  return (
    <div className="ab-ledger">
      <section aria-label="Capabilities" className="ab-ledger-list">
        <h3 className="ab-section">Capabilities</h3>
        {caps.length === 0 && <p className="ab-muted">Nothing needs you here.</p>}
        {caps.map((cap) => {
          const expanded = open === cap.id;
          const perms = permutationsFor(board, cap.id);
          return (
            <div key={cap.id} className="ab-cap" data-open={expanded || undefined}>
              <button
                type="button"
                className="ab-cap-row"
                aria-expanded={expanded}
                onClick={() => setOpen(expanded ? null : cap.id)}
              >
                <StatusMark status={cap.status} />
                <span className="ab-cap-title">{cap.title}</span>
                {cap.area && <span className="ab-tag">{cap.area}</span>}
                <CoverageBar board={board} capability={cap} />
              </button>
              {expanded && (
                <div className="ab-cap-body">
                  {cap.summary && <p className="ab-summary">{cap.summary}</p>}
                  <table className="ab-perm-table">
                    <thead>
                      <tr>
                        <th scope="col">State</th>
                        <th scope="col">Status</th>
                        <th scope="col">Evidence</th>
                      </tr>
                    </thead>
                    <tbody>
                      {perms.map((p) => (
                        <tr key={p.id} data-status={p.status}>
                          <td>{axesLabel(p.axes)}</td>
                          <td>
                            <StatusMark status={p.status} /> {STATUS_LABEL[p.status]}
                          </td>
                          <td>
                            {evidenceOf(board, p).map((e) => (
                              <EvidenceChip key={e.id} board={board} evidence={e} onOpen={onOpen} />
                            ))}
                            {p.note && <span className="ab-note">{p.note}</span>}
                            {!p.note && !p.evidence?.length && <span className="ab-muted">None yet</span>}
                          </td>
                        </tr>
                      ))}
                    </tbody>
                  </table>
                  {cap.files?.length ? (
                    <p className="ab-files">
                      {cap.files.map((f) => (
                        <code key={f}>{f}</code>
                      ))}
                    </p>
                  ) : null}
                </div>
              )}
            </div>
          );
        })}
      </section>
      <aside aria-label="Decisions" className="ab-ledger-rail">
        <h3 className="ab-section">Decisions</h3>
        {decisions.length === 0 && <p className="ab-muted">No decisions recorded.</p>}
        {decisions.map((d) => (
          <DecisionCard key={d.id} decision={d} compact />
        ))}
      </aside>
    </div>
  );
}

/** Matrix: each capability as a grid of its states, the evidence thumbnail in each cell. */
export function MatrixView({ board, needsYou, onOpen }: ViewProps) {
  const caps = visibleCapabilities(board, needsYou);
  const human = board.decisions.filter((d) => d.needsHuman);
  return (
    <div className="ab-matrix">
      {human.length > 0 && (
        <output className="ab-banner">
          <strong>
            {human.length} decision{human.length > 1 ? "s" : ""} need{human.length > 1 ? "" : "s"} you:
          </strong>{" "}
          {human.map((d) => d.title).join(", ")}
        </output>
      )}
      {caps.length === 0 && <p className="ab-muted">Nothing needs you here.</p>}
      {caps.map((cap) => {
        const perms = permutationsFor(board, cap.id).filter((p) => !needsYou || p.status !== "verified");
        return (
          <section key={cap.id} className="ab-matrix-cap" aria-label={cap.title}>
            <header className="ab-matrix-head">
              <StatusMark status={cap.status} />
              <h3>{cap.title}</h3>
              <CoverageBar board={board} capability={cap} />
            </header>
            <div className="ab-grid">
              {perms.map((p) => {
                const ev = evidenceOf(board, p);
                return (
                  <button
                    type="button"
                    key={p.id}
                    className="ab-cell"
                    data-status={p.status}
                    aria-disabled={!ev.length || undefined}
                    onClick={() => ev[0] && onOpen(ev[0])}
                    aria-label={`${axesLabel(p.axes)}: ${STATUS_LABEL[p.status]}`}
                  >
                    <Thumb permutation={p} />
                    <span className="ab-cell-axes">
                      {Object.entries(p.axes).map(([k, v]) => (
                        <span key={k} title={k}>
                          {v}
                        </span>
                      ))}
                    </span>
                    <span className="ab-cell-foot">
                      <StatusMark status={p.status} />
                      {ev.length ? `${ev.length} proof${ev.length > 1 ? "s" : ""}` : p.note ? "See note" : "No proof"}
                    </span>
                    {p.note && <span className="ab-cell-note">{p.note}</span>}
                  </button>
                );
              })}
              {perms.length === 0 && <p className="ab-muted">No states recorded yet.</p>}
            </div>
          </section>
        );
      })}
    </div>
  );
}

type StoryEvent =
  | { kind: "capability"; at: number; record: CapabilityRecord }
  | { kind: "decision"; at: number; record: DecisionRecord }
  | { kind: "evidence"; at: number; record: EvidenceRecord };

/** Story: the work in the order it happened, decisions written out with what was turned down. */
export function StoryView({ board, needsYou, onOpen }: ViewProps) {
  const attention = new Set(visibleCapabilities(board, true).map((c) => c.id));
  const events: StoryEvent[] = [
    ...board.capabilities.map((record) => ({ kind: "capability" as const, at: orderOf(board, record), record })),
    ...board.decisions.map((record) => ({ kind: "decision" as const, at: orderOf(board, record), record })),
    ...[...board.evidence.values()].map((record) => ({
      kind: "evidence" as const,
      at: orderOf(board, record),
      record,
    })),
  ]
    .filter((e) => {
      if (!needsYou) return true;
      if (e.kind === "decision") return Boolean(e.record.needsHuman);
      if (e.kind === "capability") return attention.has(e.record.id);
      return false;
    })
    .sort((a, b) => a.at - b.at);
  return (
    <ol className="ab-story">
      {events.length === 0 && <li className="ab-muted">Nothing needs you here.</li>}
      {events.map((e) => (
        <li key={`${e.kind}:${e.record.id}`} className={`ab-story-item ab-story-${e.kind}`}>
          <span className="ab-story-dot" aria-hidden="true" />
          {e.kind === "capability" && (
            <div>
              <p className="ab-story-kind">Built</p>
              <h4>
                {e.record.title} <StatusMark status={e.record.status} />
              </h4>
              {e.record.summary && <p className="ab-summary">{e.record.summary}</p>}
              <CoverageBar board={board} capability={e.record} />
            </div>
          )}
          {e.kind === "decision" && (
            <div>
              <p className="ab-story-kind">Decided</p>
              <DecisionCard decision={e.record} />
            </div>
          )}
          {e.kind === "evidence" && (
            <div className="ab-story-evidence">
              <p className="ab-story-kind">Proved</p>
              <EvidenceChip board={board} evidence={e.record} onOpen={onOpen} />
              <span>{e.record.caption}</span>
            </div>
          )}
        </li>
      ))}
    </ol>
  );
}
