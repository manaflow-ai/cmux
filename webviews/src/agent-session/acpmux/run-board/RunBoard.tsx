// l10n-allow-file: DEV gallery Run board design prototype, not shipped UI.
import { useCallback, useEffect, useReducer, useRef, useState } from "react";
import { sessionSummary } from "../summary/sessionSummary";
import {
  canApprove,
  evidenceReady,
  initialBoard,
  reduceBoard,
  selectedAttempt,
  type RunAttempt,
  type RunBoardSnapshot,
} from "./model";
import {
  RunBoardApiSession,
  type AttachTicket,
  type AttachTicketIntent,
  type RunApiClient,
} from "./runApi";

export type RunBoardProps = {
  snapshot: RunBoardSnapshot;
  recovered: RunBoardSnapshot;
  disconnected?: boolean;
  /** When supplied, the board loads and replays the durable Run control-plane API. */
  client?: RunApiClient;
  /** Host bridge that turns an attempt selection into a short-lived terminal attach ticket. */
  onAttach?: (intent: AttachTicketIntent) => Promise<AttachTicket | void>;
  /** Human approval is intentionally a callback; the board never integrates by itself. */
  onApprove?: (intent: NonNullable<ReturnType<typeof reduceBoard>["approval"]>) => Promise<void>;
  pollMs?: number;
};

function AttemptCard({
  attempt,
  selected,
  onSelect,
}: {
  attempt: RunAttempt;
  selected: boolean;
  onSelect: () => void;
}) {
  const outputs = sessionSummary(attempt.rows).outputs;
  return (
    <button
      className="run-board-attempt"
      data-state={attempt.state}
      aria-pressed={selected}
      onClick={onSelect}
      type="button"
    >
      <span className="run-board-attempt-top">
        <strong>{attempt.label}</strong>
        <span className="run-board-status">
          {attempt.state === "completed"
            ? "Ready to compare"
            : attempt.state === "failed"
              ? "Needs attention"
              : "Working"}
        </span>
      </span>
      <span className="run-board-direction">{attempt.direction}</span>
      <span className="run-board-worker">{attempt.worker}</span>
      <span className="run-board-card-rule" />
      <span className="run-board-card-row">
        <span>Build</span>
        <span data-verdict={attempt.build}>
          {attempt.build === "passed" ? "Passed" : attempt.build === "failed" ? "Failed" : "In progress"}
        </span>
      </span>
      <span className="run-board-card-row">
        <span>Tests</span>
        <span data-verdict={attempt.tests.failed ? "failed" : "passed"}>
          {attempt.tests.passed} passed{attempt.tests.failed ? ` · ${attempt.tests.failed} failed` : ""}
        </span>
      </span>
      <span className="run-board-card-row">
        <span>Evidence</span>
        <span>{attempt.artifacts.filter((item) => item.verified).length} / 3 verified</span>
      </span>
      <span className="run-board-card-row">
        <span>Changes</span>
        <span>{outputs.length} files</span>
      </span>
      <span className="run-board-activity">{attempt.activity}</span>
      <span className="run-board-card-bottom">
        {selected ? "Viewing workspace" : "View workspace"}
        <span aria-hidden="true">↗</span>
      </span>
    </button>
  );
}

function WorkspacePreview({ attempt }: { attempt: RunAttempt }) {
  return (
    <div className="run-board-preview" data-layout={attempt.id} aria-label={`${attempt.label} sample UI preview`}>
      <div className="run-board-preview-bar">
        <span>◉ &nbsp; atlas</span>
        <span>Workspace &nbsp; / &nbsp; Overview</span>
        <span>⌘ K</span>
      </div>
      <div className="run-board-preview-body">
        <aside>
          <b>Projects</b>
          <span>◈ &nbsp; Overview</span>
          <span>□ &nbsp; All tasks</span>
          <span>◷ &nbsp; Activity</span>
          <span>◇ &nbsp; Settings</span>
        </aside>
        <div className="run-board-preview-main">
          <small>YOUR WORKSPACE</small>
          <h3>Make room for the work.</h3>
          <p>A quieter home for everything your team is building.</p>
          <div className="run-board-preview-tiles">
            {["In progress", "Ready for review", "Recently shipped"].map((name, index) => (
              <div key={name}>
                <small>{name}</small>
                <strong>{[12, 4, 28][index]}</strong>
                <span className="run-board-preview-line" />
                <span className="run-board-preview-line short" />
              </div>
            ))}
          </div>
          <div className="run-board-preview-list">
            <span>Today</span>
            <p>
              Refresh workspace navigation <small>Design</small>
            </p>
            <p>
              Improve the first run experience <small>Product</small>
            </p>
          </div>
        </div>
      </div>
      <span className="run-board-sample">Sample artifact · gallery fixture</span>
    </div>
  );
}

export function RunBoard({ snapshot, recovered, disconnected = false, client, onAttach, onApprove, pollMs = 4_000 }: RunBoardProps) {
  const [state, dispatch] = useReducer(reduceBoard, undefined, () => initialBoard(snapshot, disconnected));
  const [tab, setTab] = useState<"preview" | "activity">("preview");
  const [apiError, setApiError] = useState<string>();
  const [actionPending, setActionPending] = useState<"attach" | "approve">();
  const stateRef = useRef<ReturnType<typeof initialBoard> | undefined>(undefined);
  stateRef.current = state;
  const apiSession = useRef<RunBoardApiSession | undefined>(undefined);
  const apiClient = useRef<RunApiClient | undefined>(undefined);
  const apiRunId = useRef<string | undefined>(undefined);
  const reconnect = useCallback(async () => {
    if (!client) {
      dispatch({ type: "receive", snapshot: recovered });
      return;
    }
    const session = apiSession.current;
    if (!session) return;
    try {
      setApiError(undefined);
      const next = await session.snapshotAndReplay();
      dispatch({ type: "receive", snapshot: next });
    } catch (error) {
      setApiError(error instanceof Error ? error.message : String(error));
    }
  }, [client, recovered]);

  useEffect(() => {
    if (!client || (apiClient.current === client && apiRunId.current === snapshot.id)) return;
    apiClient.current = client;
    apiRunId.current = snapshot.id;
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
  }, [client, disconnected, pollMs]);

  const attempt = selectedAttempt(state);
  const approved = state.snapshot.attempts.find((item) => item.id === state.approval?.attemptId);
  const done = state.snapshot.attempts.filter((item) => evidenceReady(item)).length;
  const reviewed = Boolean(state.reviewed);
  const attach = async () => {
    if (!attempt || state.connection !== "live" || actionPending) return;
    const intent: AttachTicketIntent = {
      runId: state.snapshot.id,
      attemptId: attempt.id,
      sessionId: attempt.sessionId,
      cursor: state.snapshot.cursor,
    };
    try {
      setApiError(undefined);
      setActionPending("attach");
      const ticket = await onAttach?.(intent);
      dispatch({ type: "attach", ...(ticket ? { ticket } : {}) });
    } catch (error) {
      setApiError(error instanceof Error ? error.message : String(error));
    } finally {
      setActionPending(undefined);
    }
  };
  const approve = async () => {
    if (!canApprove(state) || actionPending) return;
    const candidate = reduceBoard(state, { type: "approve" }).approval;
    if (!candidate) return;
    try {
      setApiError(undefined);
      setActionPending("approve");
      await onApprove?.(candidate);
      dispatch({ type: "approve" });
    } catch (error) {
      setApiError(error instanceof Error ? error.message : String(error));
    } finally {
      setActionPending(undefined);
    }
  };
  return (
    <main className="run-board" data-connection={state.connection} data-approved={state.approval?.attemptId ?? ""} data-api-error={apiError ?? ""}>
      <header className="run-board-header">
        <div>
          <div className="run-board-eyebrow">
            RUN {state.snapshot.id} <span>UI exploration</span>
          </div>
          <h1>{state.snapshot.title}</h1>
          <p>
            {state.snapshot.source} <span>·</span> {state.snapshot.attempts.length} independent workspaces <span>·</span> {done} ready to compare
          </p>
        </div>
        <div className="run-board-connection">
          <span className="run-board-live-dot" />
          {state.connection === "live" ? "Live" : "Disconnected"}
          <small>Event {state.snapshot.cursor}</small>
        </div>
      </header>
      <section className="run-board-intent" aria-label="Shared intent">
        <span>Shared intent</span>
        <p>{state.snapshot.intent}</p>
        <span className="run-board-isolation">
          Same starting commit · Separate workspaces · No cross-attempt context
        </span>
      </section>
      {state.connection === "disconnected" && (
        <div className="run-board-reconnect" aria-live="polite">
          <div>
            <strong>Your workers are still running.</strong>
            <span>Showing the last saved events. Reconnect to recover every attempt.</span>
          </div>
          <button type="button" onClick={() => void reconnect()}>
            Reconnect and replay
          </button>
        </div>
      )}
      {apiError && <p className="run-board-api-error" role="alert">{apiError}</p>}
      <section className="run-board-attempts" aria-label="Independent attempts">
        {state.snapshot.attempts.map((item) => (
          <AttemptCard
            key={item.id}
            attempt={item}
            selected={item.id === state.selected}
            onSelect={() => dispatch({ type: "select", attemptId: item.id })}
          />
        ))}
      </section>
      {attempt && (
        <section className="run-board-workspace" aria-label="Selected attempt workspace">
          <div className="run-board-workspace-toolbar">
            <div>
              <strong>{attempt.label}</strong>
              <span>
                {attempt.worker} <span> / </span> {attempt.sessionId}
              </span>
            </div>
            <fieldset className="run-board-tabs" aria-label="Workspace view">
              <button type="button" aria-pressed={tab === "preview"} onClick={() => setTab("preview")}>
                Preview
              </button>
              <button type="button" aria-pressed={tab === "activity"} onClick={() => setTab("activity")}>
                Agent activity
              </button>
            </fieldset>
            <button
              className="run-board-attach"
              type="button"
              disabled={state.connection !== "live" || attempt.attachable === false || actionPending === "attach"}
              onClick={() => void attach()}
            >
              {actionPending === "attach" ? "Attaching…" : state.attached === attempt.id ? "Attached to agent" : attempt.attachable === false ? "Terminal expired" : "Attach to agent"}
              <span aria-hidden="true">↗</span>
            </button>
          </div>
          <div className="run-board-workspace-content">
            {tab === "preview" ? (
              <WorkspacePreview attempt={attempt} />
            ) : (
              <div className="run-board-transcript" aria-label="Agent activity">
                {attempt.rows
                  .filter((row) => row.kind === "assistant" || row.kind === "activity")
                  .map((row) => (
                    <div key={row.id}>
                      <small>{row.kind === "assistant" ? "Agent" : "Tools"}</small>
                      <p>{row.text ?? row.items?.map((item) => item.text).join(" · ")}</p>
                      {row.items?.map((item) => item.tool?.output && <pre key={item.tool.id}>{item.tool.output}</pre>)}
                    </div>
                  ))}
              </div>
            )}
            <aside className="run-board-evidence">
              <h2>Evidence</h2>
              <p>Build and test receipts stay with this attempt.</p>
              <div className="run-board-evidence-check">
                <span data-verdict={attempt.build}>
                  {attempt.build === "passed" ? "✓" : attempt.build === "failed" ? "!" : "○"}
                </span>
                <div>
                  <strong>Build {attempt.build}</strong>
                  <small>
                    {attempt.tests.passed} tests passed{attempt.tests.failed ? `, ${attempt.tests.failed} failed` : ""}
                  </small>
                </div>
              </div>
              {attempt.artifacts.map((artifact) => (
                <div className="run-board-evidence-file" key={artifact.id}>
                  <span aria-hidden="true">
                    {artifact.kind === "recording" ? "▷" : artifact.kind === "patch" ? "±" : "▧"}
                  </span>
                  <div>
                    <strong>{artifact.name}</strong>
                    <small>{artifact.verified ? "Digest verified" : "Awaiting verification"}</small>
                  </div>
                  <span data-verdict={artifact.verified ? "passed" : "pending"}>{artifact.verified ? "✓" : "○"}</span>
                </div>
              ))}
              {attempt.artifacts.length === 0 && (
                <p className="run-board-empty-evidence">
                  The agent will publish its screenshot, recording and patch here.
                </p>
              )}
              <span className="run-board-evidence-note">Original artifacts remain owned by this attempt.</span>
            </aside>
          </div>
          <footer className="run-board-approval">
            <div>
              <strong>{state.approval ? "Integration requested" : "Choose what moves forward"}</strong>
              <p>
                {state.approval
                  ? `${approved?.label ?? state.approval.attemptId} is queued for a separate integration review.`
                  : "Review the UI, recording and diff before approving a candidate."}
              </p>
            </div>
            <label>
              <input
                type="checkbox"
                aria-label="I reviewed this attempt"
                checked={reviewed}
                disabled={!evidenceReady(attempt) || state.connection !== "live" || Boolean(state.approval)}
                onChange={(event) => dispatch({ type: "review", checked: event.currentTarget.checked })}
              />
              I reviewed this attempt
            </label>
            <button type="button" disabled={!canApprove(state) || actionPending === "approve"} onClick={() => void approve()}>
              {actionPending === "approve" ? "Promoting…" : state.approval ? "Promotion requested" : "Promote winner"}
            </button>
          </footer>
        </section>
      )}
      <footer className="run-board-footnote">
        <span>Team Run board · durable control plane</span>
        <span>Fan-out → evidence → compare → promote a winner</span>
      </footer>
    </main>
  );
}
