// l10n-allow-file: DEV gallery Run board comparison variant, not shipped UI.
import { useCallback, useEffect, useReducer, useRef, useState } from "react";
import { sessionSummary } from "../../../summary/sessionSummary";
import {
  canApprove,
  evidenceReady,
  initialBoard,
  reduceBoard,
  selectedAttempt,
  type RunAttempt,
  type RunBoardSnapshot,
} from "../../model";
import {
  RunApiHttpError,
  RunBoardApiSession,
  type AttachTicketIntent,
  type RunApiClient,
  type RunAttachTicket,
} from "../../runApi";
import { attachFailureState, attachTicketExpired } from "../../RunBoard";
import { attachRunTerminal } from "../../runAttach";

export type CompareRunBoardProps = {
  snapshot: RunBoardSnapshot;
  recovered: RunBoardSnapshot;
  disconnected?: boolean;
  client?: RunApiClient;
  onAttach?: (intent: AttachTicketIntent) => Promise<RunAttachTicket | void>;
  onAttachTicket?: (ticket: RunAttachTicket) => Promise<void>;
  onApprove?: (intent: NonNullable<ReturnType<typeof reduceBoard>["approval"]>) => Promise<void>;
  pollMs?: number;
};

type Tab = "preview" | "activity";

function statusLabel(attempt: RunAttempt): string {
  if (attempt.state === "failed") return "Needs attention";
  if (attempt.state === "running") return "Working";
  if (evidenceReady(attempt)) return "Ready to review";
  return "Evidence pending";
}

function verdictLabel(value: RunAttempt["build"]): string {
  return value === "passed" ? "Passed" : value === "failed" ? "Failed" : "Pending";
}

function MiniPreview({ attempt, detail = false }: { attempt: RunAttempt; detail?: boolean }) {
  const values = attempt.id === "attempt-b" ? [8, 3, 19] : attempt.id === "attempt-c" ? [18, 6, 31] : [12, 4, 28];
  return (
    <div
      className={`compare-preview ${detail ? "compare-preview-detail" : ""}`}
      data-layout={attempt.id}
      aria-label={`${attempt.label} UI preview`}
    >
      <div className="compare-preview-bar">
        <strong>
          <span aria-hidden="true">◉</span> atlas
        </strong>
        <span>
          Workspace <span aria-hidden="true">/</span> Overview
        </span>
        <span className="compare-preview-key">⌘ K</span>
      </div>
      <div className="compare-preview-body">
        <aside aria-hidden="true">
          <b>Projects</b>
          <span>◈ Overview</span>
          <span>□ All tasks</span>
          <span>◷ Activity</span>
          <span>◇ Settings</span>
        </aside>
        <div className="compare-preview-main">
          <small>YOUR WORKSPACE</small>
          <h3>{attempt.id === "attempt-b" ? "A calmer place to focus." : "Make room for the work."}</h3>
          <p>{attempt.direction}</p>
          <div className="compare-preview-tiles">
            {["In progress", "Ready for review", "Recently shipped"].map((name, index) => (
              <div key={name}>
                <small>{name}</small>
                <strong>{values[index]}</strong>
                <span className="compare-preview-line" />
                <span className="compare-preview-line short" />
              </div>
            ))}
          </div>
          {detail && (
            <div className="compare-preview-list">
              <b>Today</b>
              <p>
                Refresh workspace navigation <small>Design</small>
              </p>
              <p>
                Improve the first run experience <small>Product</small>
              </p>
            </div>
          )}
        </div>
      </div>
      <span className="compare-preview-caption">Recorded UI preview · {attempt.label}</span>
    </div>
  );
}

function CandidateCard({
  attempt,
  selected,
  onSelect,
  onAttach,
  attachLabel,
  attachDisabled,
}: {
  attempt: RunAttempt;
  selected: boolean;
  onSelect: () => void;
  onAttach: () => void;
  attachLabel: string;
  attachDisabled: boolean;
}) {
  const changes = sessionSummary(attempt.rows).outputs.length;
  const verified = attempt.artifacts.filter((artifact) => artifact.verified).length;
  return (
    <li className="compare-candidate" data-state={attempt.state} data-selected={selected ? attempt.id : ""}>
      <div className="compare-candidate-head">
        <button
          className="compare-candidate-select"
          type="button"
          aria-pressed={selected}
          data-select-attempt={attempt.id}
          aria-label={`Select ${attempt.label} as comparison winner`}
          onClick={onSelect}
        >
          <span className="compare-candidate-index" aria-hidden="true">
            {attempt.label.slice(-1)}
          </span>
          <span>
            <strong>{attempt.label}</strong>
            <span className="compare-candidate-meta">
              <small>{attempt.direction}</small>
              <small className="compare-provider-badge">
                <span aria-hidden="true">⌁</span> {attempt.worker}
              </small>
            </span>
          </span>
        </button>
        <span className="compare-candidate-state" data-verdict={attempt.state}>
          <span className="compare-state-dot" aria-hidden="true" /> {statusLabel(attempt)}
        </span>
      </div>
      <button
        className="compare-candidate-preview-button"
        type="button"
        onClick={onSelect}
        aria-label={`Preview ${attempt.label}`}
      >
        <MiniPreview attempt={attempt} />
      </button>
      <div className="compare-candidate-metrics" aria-label={`${attempt.label} synchronized status`}>
        <div>
          <span>Build</span>
          <strong data-verdict={attempt.build}>{verdictLabel(attempt.build)}</strong>
        </div>
        <div>
          <span>Tests</span>
          <strong data-verdict={attempt.tests.failed ? "failed" : "passed"}>
            {attempt.tests.passed} / {attempt.tests.passed + attempt.tests.failed}
          </strong>
        </div>
        <div>
          <span>Evidence</span>
          <strong>{verified} / 3</strong>
        </div>
        <div>
          <span>Changes</span>
          <strong>{changes} files</strong>
        </div>
      </div>
      <p className="compare-candidate-activity">{attempt.activity}</p>
      <div className="compare-candidate-footer">
        <span>{selected ? "Winner under review" : "Select to review"}</span>
        <button
          type="button"
          className="compare-attach-button"
          aria-label={`Attach terminal to ${attempt.label}`}
          disabled={attachDisabled}
          onClick={onAttach}
        >
          {attachLabel} <span aria-hidden="true">↗</span>
        </button>
      </div>
    </li>
  );
}

function ActivityTrace({ attempt }: { attempt: RunAttempt }) {
  const rows = attempt.rows.filter((row) => row.kind === "assistant" || row.kind === "activity").slice(-4);
  return (
    <div className="compare-activity" aria-label={`${attempt.label} agent activity`}>
      <div className="compare-panel-title">
        <span>Durable activity</span>
        <small>{attempt.worker}</small>
      </div>
      {rows.map((row) => (
        <div className="compare-activity-row" key={row.id}>
          <small>{row.kind === "assistant" ? "Agent" : "Tools"}</small>
          <p>{row.text ?? row.items?.map((item) => item.text).join(" · ")}</p>
          {row.items?.map((item) => item.tool?.output && <pre key={item.tool.id}>{item.tool.output}</pre>)}
        </div>
      ))}
    </div>
  );
}

function EvidenceRail({ attempt }: { attempt: RunAttempt }) {
  return (
    <aside className="compare-evidence" aria-label={`${attempt.label} evidence`}>
      <div className="compare-panel-title">
        <span>Evidence ledger</span>
        <small>Cursor-bound</small>
      </div>
      <div className="compare-evidence-build">
        <span className="compare-evidence-icon" data-verdict={attempt.build}>
          {attempt.build === "passed" ? "✓" : attempt.build === "failed" ? "!" : "○"}
        </span>
        <span>
          <strong>Build {verdictLabel(attempt.build)}</strong>
          <small>
            {attempt.tests.passed} tests passed{attempt.tests.failed ? ` · ${attempt.tests.failed} failed` : ""}
          </small>
        </span>
      </div>
      <ul className="compare-evidence-list">
        {attempt.artifacts.map((artifact) => (
          <li key={artifact.id}>
            <span className="compare-evidence-kind" aria-hidden="true">
              {artifact.kind === "recording" ? "▷" : artifact.kind === "patch" ? "±" : "▧"}
            </span>
            <span>
              <strong>{artifact.name}</strong>
              <small>{artifact.verified ? "Digest verified" : "Awaiting verification"}</small>
            </span>
            <b data-verdict={artifact.verified ? "passed" : "pending"}>{artifact.verified ? "✓" : "○"}</b>
          </li>
        ))}
      </ul>
      {attempt.artifacts.length === 0 && (
        <p className="compare-empty-evidence">
          Evidence will appear when the worker publishes its screenshot, recording and patch.
        </p>
      )}
      <p className="compare-evidence-note">Original artifacts remain owned by this attempt.</p>
    </aside>
  );
}

export function CompareRunBoard({
  snapshot,
  recovered,
  disconnected = false,
  client,
  onAttach,
  onAttachTicket,
  onApprove,
  pollMs = 4_000,
}: CompareRunBoardProps) {
  const [state, dispatch] = useReducer(reduceBoard, undefined, () => initialBoard(snapshot, disconnected));
  const [tab, setTab] = useState<Tab>("preview");
  const [apiError, setApiError] = useState<string>();
  const [actionPending, setActionPending] = useState<"attach" | "approve">();
  const [pendingAttempt, setPendingAttempt] = useState<string>();
  const [attachAttempt, setAttachAttempt] = useState<string>();
  const [attachState, setAttachState] = useState<"idle" | "attached" | "expired" | "replayed" | "error">("idle");
  const [replayComplete, setReplayComplete] = useState(!disconnected);
  const [actionReceipt, setActionReceipt] = useState("Ready for comparison.");
  const stateRef = useRef<ReturnType<typeof initialBoard> | undefined>(undefined);
  stateRef.current = state;
  const apiSession = useRef<RunBoardApiSession | undefined>(undefined);
  const apiClient = useRef<RunApiClient | undefined>(undefined);

  const reconnect = useCallback(async () => {
    if (!client) {
      dispatch({ type: "receive", snapshot: recovered });
      setReplayComplete(true);
      setActionReceipt(`Replayed through event ${recovered.cursor}.`);
      return;
    }
    const session = apiSession.current;
    if (!session) return;
    try {
      setApiError(undefined);
      const next = await session.snapshotAndReplay();
      dispatch({ type: "receive", snapshot: next });
      setReplayComplete(true);
      setActionReceipt(`Replayed through event ${next.cursor}.`);
    } catch (error) {
      setApiError(error instanceof Error ? error.message : String(error));
    }
  }, [client, recovered]);

  useEffect(() => {
    if (!client || apiClient.current === client) return;
    apiClient.current = client;
    apiSession.current = new RunBoardApiSession(snapshot.id, client);
  }, [client, snapshot.id]);

  useEffect(() => {
    if (!client || disconnected || !apiSession.current) return;
    let active = true;
    const refresh = async () => {
      const session = apiSession.current;
      if (!session || !active) return;
      try {
        const next = await session.replay(stateRef.current?.snapshot ?? snapshot);
        if (active) dispatch({ type: "receive", snapshot: next });
      } catch (error) {
        if (active) setApiError(error instanceof Error ? error.message : String(error));
      }
    };
    void (async () => {
      const session = apiSession.current;
      if (!session) return;
      try {
        const next = await session.snapshotAndReplay();
        if (active) dispatch({ type: "receive", snapshot: next });
      } catch (error) {
        if (active) setApiError(error instanceof Error ? error.message : String(error));
      }
    })();
    const timer = pollMs > 0 ? setInterval(() => void refresh(), pollMs) : undefined;
    return () => {
      active = false;
      if (timer) clearInterval(timer);
    };
  }, [client, disconnected, pollMs, snapshot]);

  const attempt = selectedAttempt(state);
  const approved = state.snapshot.attempts.find((item) => item.id === state.approval?.attemptId);
  const readyCount = state.snapshot.attempts.filter((item) => evidenceReady(item)).length;
  const reviewed = Boolean(state.reviewed);

  const attach = async (target: RunAttempt) => {
    if (state.connection !== "live" || actionPending) return;
    const intent: AttachTicketIntent = {
      runId: state.snapshot.id,
      attemptId: target.id,
      sessionId: target.sessionId,
      cursor: state.snapshot.cursor,
    };
    try {
      setApiError(undefined);
      setAttachState("idle");
      setAttachAttempt(target.id);
      setPendingAttempt(target.id);
      setActionPending("attach");
      const ticket = onAttach
        ? await onAttach(intent)
        : client?.requestAttachTicket
          ? await client.requestAttachTicket(intent)
          : undefined;
      if (ticket && attachTicketExpired(ticket)) {
        throw new RunApiHttpError(
          410,
          "This attach ticket has expired. Request a fresh ticket and try again.",
          "run_attach_expired",
        );
      }
      if (ticket) await (onAttachTicket ?? attachRunTerminal)(ticket);
      dispatch({ type: "select", attemptId: target.id });
      dispatch({ type: "attach", ...(ticket ? { ticket } : {}) });
      setAttachState(ticket ? "attached" : "idle");
      setActionReceipt(ticket ? `Attached terminal to ${target.label}.` : `Attach requested for ${target.label}.`);
    } catch (error) {
      setAttachState(attachFailureState(error));
      setApiError(error instanceof Error ? error.message : String(error));
    } finally {
      setPendingAttempt(undefined);
      setActionPending(undefined);
    }
  };

  const approve = async () => {
    if (!canApprove(state) || actionPending) return;
    const candidate = reduceBoard(state, { type: "approve" }).approval;
    if (!candidate || !attempt) return;
    try {
      setApiError(undefined);
      setActionPending("approve");
      await onApprove?.(candidate);
      dispatch({ type: "approve" });
      setActionReceipt(`${attempt.label} approved for integration review.`);
    } catch (error) {
      setApiError(error instanceof Error ? error.message : String(error));
    } finally {
      setActionPending(undefined);
    }
  };

  const attachLabel = (target: RunAttempt) => {
    if (actionPending === "attach" && pendingAttempt === target.id) return "Attaching…";
    if (state.attached === target.id && attachState === "attached") return "Terminal attached";
    if (attachState === "expired" && attachAttempt === target.id) return "Attach expired · Retry";
    if (attachState === "replayed" && attachAttempt === target.id) return "Attach used · Retry";
    if (attachState === "error" && attachAttempt === target.id) return "Attach failed · Retry";
    return "Attach terminal";
  };

  return (
    <main
      className="compare-run-board"
      data-connection={state.connection}
      data-replay-state={state.connection === "disconnected" ? "offline" : replayComplete ? "replayed" : "live"}
      data-approved={state.approval?.attemptId ?? ""}
      data-selected-attempt={state.selected}
      data-attach-state={attachState}
      data-api-error={apiError ?? ""}
    >
      <header className="compare-run-header">
        <div>
          <div className="compare-run-eyebrow">
            RUN {state.snapshot.id} <span>COMPARISON STAGE</span>
          </div>
          <h1>{state.snapshot.title}</h1>
          <p>
            {state.snapshot.source} <span aria-hidden="true">·</span> {state.snapshot.attempts.length} independent
            candidates <span aria-hidden="true">·</span> {readyCount} ready to compare
          </p>
        </div>
        <div className="compare-run-connection" aria-live="polite">
          <span className="compare-live-dot" aria-hidden="true" />
          {state.connection === "live" ? "Live owner" : "Offline mirror"}
          <small>Event {state.snapshot.cursor}</small>
        </div>
      </header>

      <section className="compare-run-intent" aria-label="Shared intent">
        <div>
          <span>Shared intent</span>
          <p>{state.snapshot.intent}</p>
        </div>
        <small>
          Same starting commit <span aria-hidden="true">·</span> Separate workspaces <span aria-hidden="true">·</span>{" "}
          Synchronized event cursor
        </small>
      </section>

      {state.connection === "disconnected" && (
        <section className="compare-replay-banner" data-replay-banner aria-live="polite">
          <span className="compare-replay-icon" aria-hidden="true">
            ↻
          </span>
          <div>
            <strong>Offline mirror · workers continue independently</strong>
            <span>
              Showing the last durable snapshot. Reconnect to replay the owner event stream and recover finished
              evidence.
            </span>
          </div>
          <button type="button" onClick={() => void reconnect()}>
            Reconnect and replay <span aria-hidden="true">↗</span>
          </button>
        </section>
      )}
      {apiError && (
        <p className="compare-api-error" role="alert">
          {apiError}
        </p>
      )}

      <section className="compare-matrix-section" aria-labelledby="compare-matrix-title">
        <div className="compare-matrix-heading">
          <div>
            <span className="compare-section-kicker">COMPARE IN PARALLEL</span>
            <h2 id="compare-matrix-title">
              Candidate matrix <small>2 × 2</small>
            </h2>
          </div>
          <output className="compare-capture-receipt" data-testid="compare-capture-receipt" aria-live="polite">
            Capture receipt · {state.snapshot.attempts.length} previews · event {state.snapshot.cursor} ·{" "}
            {actionReceipt}
          </output>
        </div>
        <ul className="compare-matrix" aria-label="Independent candidate attempts">
          {state.snapshot.attempts.map((item) => (
            <CandidateCard
              key={item.id}
              attempt={item}
              selected={item.id === state.selected}
              onSelect={() => dispatch({ type: "select", attemptId: item.id })}
              onAttach={() => void attach(item)}
              attachLabel={attachLabel(item)}
              attachDisabled={state.connection !== "live" || Boolean(actionPending)}
            />
          ))}
        </ul>
      </section>

      {attempt && (
        <section className="compare-review" aria-labelledby="compare-review-title">
          <header className="compare-review-header">
            <div>
              <span className="compare-section-kicker">WINNER / REVIEW</span>
              <h2 id="compare-review-title">
                {attempt.label}
                <span aria-hidden="true"> · </span>
                {attempt.direction}
              </h2>
              <p>
                {attempt.worker} <span aria-hidden="true">/</span> {attempt.sessionId}
              </p>
            </div>
            <div
              className="compare-review-state"
              data-review-state={state.approval ? "approved" : reviewed ? "reviewed" : "unreviewed"}
            >
              <span aria-hidden="true">{state.approval ? "✓" : reviewed ? "◉" : "○"}</span>
              {state.approval
                ? "Winner approved"
                : reviewed
                  ? "Ready to approve"
                  : evidenceReady(attempt)
                    ? "Review evidence"
                    : "Evidence pending"}
            </div>
          </header>
          <div className="compare-review-toolbar">
            <fieldset className="compare-tabs">
              <legend className="compare-tabs-label">Winner detail view</legend>
              <button type="button" aria-pressed={tab === "preview"} onClick={() => setTab("preview")}>
                Side-by-side preview
              </button>
              <button type="button" aria-pressed={tab === "activity"} onClick={() => setTab("activity")}>
                Activity trace
              </button>
            </fieldset>
            <button
              type="button"
              className="compare-detail-attach"
              disabled={state.connection !== "live" || Boolean(actionPending)}
              onClick={() => void attach(attempt)}
            >
              {attachLabel(attempt)} <span aria-hidden="true">↗</span>
            </button>
          </div>
          <div className="compare-review-content">
            <div className="compare-review-main">
              {tab === "preview" ? (
                <div className="compare-side-by-side" aria-label="Selected candidate preview and baseline">
                  <div>
                    <span className="compare-pane-label">Candidate preview</span>
                    <MiniPreview attempt={attempt} detail />
                  </div>
                  <div className="compare-baseline">
                    <span className="compare-pane-label">Shared starting surface</span>
                    <div className="compare-baseline-surface">
                      <strong>Baseline</strong>
                      <span>Compare this candidate against the same intent and commit.</span>
                      <i />
                      <i className="short" />
                      <i className="tiny" />
                    </div>
                  </div>
                </div>
              ) : (
                <ActivityTrace attempt={attempt} />
              )}
            </div>
            <EvidenceRail attempt={attempt} />
          </div>
          <footer className="compare-approval-bar">
            <div>
              <strong>{state.approval ? "Integration review requested" : "Choose what moves forward"}</strong>
              <p>
                {state.approval
                  ? `${approved?.label ?? state.approval.attemptId} is queued with its cursor and artifact digests.`
                  : "Inspect the preview, activity and evidence before approving a winner."}
              </p>
            </div>
            <label>
              <input
                type="checkbox"
                aria-label={`I reviewed ${attempt.label}`}
                checked={reviewed}
                disabled={!evidenceReady(attempt) || state.connection !== "live" || Boolean(state.approval)}
                onChange={(event) => dispatch({ type: "review", checked: event.currentTarget.checked })}
              />{" "}
              I reviewed this candidate
            </label>
            <button
              className="compare-approve"
              type="button"
              disabled={!canApprove(state) || Boolean(actionPending)}
              onClick={() => void approve()}
            >
              {actionPending === "approve"
                ? "Recording approval…"
                : state.approval
                  ? "Approval recorded"
                  : `Approve ${attempt.label} for integration`}
            </button>
          </footer>
        </section>
      )}

      <footer className="compare-run-footnote">
        <span>Comparison variant · durable run evidence</span>
        <span>
          Matrix <span aria-hidden="true">→</span> review <span aria-hidden="true">→</span> attach{" "}
          <span aria-hidden="true">→</span> approve
        </span>
      </footer>
    </main>
  );
}
