import React, { useRef, useState } from "react";
import { agentDisplayName } from "../agents";
import type { HandoffClientState } from "./client";
import type { Handoff } from "./protocol";
import { reviewedContinuation, type HandoffReviewInput } from "./review";
import { formatHandoff, type HandoffStrings } from "./strings";
import "./styles.css";

/** Review is the target's first message. Only Start delivers context to the agent. */
export function HandoffReviewMessage({
  record,
  state,
  strings: s,
  onSave,
  onStart,
  onReturn,
  onDiscard,
  onReload,
}: {
  record: Handoff;
  state: HandoffClientState;
  strings: HandoffStrings;
  onSave: (review: HandoffReviewInput) => Promise<Handoff | undefined>;
  onStart: (review: HandoffReviewInput) => Promise<unknown>;
  onReturn: () => void;
  onDiscard: () => void;
  onReload: () => void;
}) {
  const [capsule, setCapsule] = useState(record.capsule.text);
  const [checkpoint, setCheckpoint] = useState(record.capsule.checkpoint?.ref ?? "");
  const [confirmed, setConfirmed] = useState(!!record.capsule.checkpoint);
  const [memory, setMemory] = useState(record.capsule.memoryRefs.join("\n"));
  const [validationError, setValidationError] = useState<string>();
  const base = useRef(record.revision);
  const edits = useRef(0);
  const busy =
    (!!state.busy && state.busy !== "saving") || !state.ready || record.state === "started" || !!state.receipt;
  const editable = !busy && record.state === "draft";
  const input = (): HandoffReviewInput => ({
    capsule,
    checkpoint: { reference: checkpoint, confirmed },
    approvedMemoryReferences: [
      ...new Set(
        memory
          .split(/\r?\n/)
          .map((v) => v.trim())
          .filter(Boolean),
      ),
    ],
    revision: base.current,
  });
  const save = async () => {
    if (!editable || state.conflict || !edits.current) return;
    const version = edits.current;
    try {
      const saved = await onSave(input());
      if (saved) {
        base.current = saved.revision;
        if (edits.current === version) edits.current = 0;
      }
    } catch {
      /* RPC errors are projected by the owner client; retain all local edits. */
    }
  };
  const changed = () => {
    edits.current += 1;
    setValidationError(undefined);
  };
  return (
    <section className="acpmux-handoff-review" aria-label={s.review}>
      <p className="acpmux-handoff-provenance">
        {formatHandoff(s.fromTo, agentDisplayName(record.source.harness), agentDisplayName(record.target.harness))}
      </p>
      <p className="acpmux-handoff-project">{record.target.cwd}</p>
      <form
        onSubmit={async (event) => {
          event.preventDefault();
          if (busy || state.conflict) return;
          try {
            const review = reviewedContinuation(capsule, checkpoint, confirmed, memory, record.capsule.maxBytes, s);
            setValidationError(undefined);
            await onStart({ ...review, revision: base.current });
          } catch (error) {
            setValidationError(error instanceof Error ? error.message : s.failedReview);
          }
        }}
      >
        <label>
          {s.context}
          <textarea
            aria-label={s.context}
            value={capsule}
            rows={10}
            disabled={!editable}
            onChange={(e) => {
              changed();
              setCapsule(e.target.value);
            }}
            onBlur={() => void save()}
          />
        </label>
        <label>
          {s.checkpoint}
          <input
            aria-label={s.checkpoint}
            value={checkpoint}
            placeholder={s.checkpointPlaceholder}
            disabled={!editable}
            onChange={(e) => {
              changed();
              setCheckpoint(e.target.value);
              setConfirmed(false);
            }}
            onBlur={() => void save()}
          />
        </label>
        <label className="acpmux-handoff-confirm">
          <input
            aria-label={s.checkpointConfirm}
            type="checkbox"
            checked={confirmed}
            disabled={!editable}
            onChange={(e) => {
              changed();
              setConfirmed(e.target.checked);
            }}
            onBlur={() => void save()}
          />
          {s.checkpointConfirm}
        </label>
        <details>
          <summary>{s.memory}</summary>
          <label>
            {s.memoryHelp}
            <textarea
              aria-label={s.memoryHelp}
              value={memory}
              rows={3}
              disabled={!editable}
              onChange={(e) => {
                changed();
                setMemory(e.target.value);
              }}
              onBlur={() => void save()}
            />
          </label>
        </details>
        <details className="acpmux-handoff-coverage">
          <summary>{s.coverage}</summary>
          {[record.source, record.target].map((session, i) => (
            <div key={session.sessionId}>
              <p>
                {i === 0 ? s.source : s.target}: {agentDisplayName(session.harness)}
              </p>
              <p title={session.enforcement.detail ?? s.unverifiedDetail}>
                {s.nativePolicy}: {session.enforcement.policy}
              </p>
              <ul>
                {session.coverage.map((report) => (
                  <li key={report.item}>
                    {s[report.item]}: {s[report.status]}
                    {report.detail ? ` · ${report.detail}` : ""}
                  </li>
                ))}
              </ul>
            </div>
          ))}
        </details>
        {(validationError || state.error) && <p role="alert">{validationError || state.error}</p>}
        {state.busy === "saving" && <output>{s.saving}</output>}
        <div className="acpmux-handoff-buttons">
          <button
            type="submit"
            disabled={busy || !!state.conflict || !capsule.trim() || !checkpoint.trim() || !confirmed}
          >
            {state.busy === "starting" || record.state === "starting"
              ? s.starting
              : formatHandoff(s.continueTarget, agentDisplayName(record.target.harness))}
          </button>
          <button type="button" onClick={onReturn}>
            {s.returnSource}
          </button>
          <button type="button" onClick={onDiscard} disabled={!!state.busy || !state.ready || record.state !== "draft"}>
            {s.discard}
          </button>
          <button type="button" onClick={onReload} disabled={!!state.busy}>
            {s.reload}
          </button>
        </div>
      </form>
    </section>
  );
}
