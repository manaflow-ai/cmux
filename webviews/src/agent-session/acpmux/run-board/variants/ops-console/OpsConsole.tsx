// l10n-allow-file: gallery Run board design prototype, not shipped UI.
import { useCallback, useEffect, useReducer, useRef, useState } from "react";
import { evidenceReady, initialBoard, reduceBoard, runReceipt, selectedAttempt, type RunAttempt } from "../../model";
import type { RunBoardProps } from "../../RunBoard";
import { attachFailureState, attachTicketExpired } from "../../RunBoard";
import {
  RunApiHttpError,
  RunBoardApiSession,
  type AttachTicketIntent,
  type RunApiClient,
} from "../../runApi";
import { attachRunTerminal } from "../../runAttach";

type AttachState = "idle" | "attached" | "expired" | "replayed" | "error";

export type OpsConsoleProps = RunBoardProps;

function AttemptRail({
  attempts,
  selected,
  attached,
  promoted,
  onSelect,
}: {
  attempts: RunAttempt[];
  selected: string;
  attached?: string;
  promoted?: string;
  onSelect: (id: string) => void;
}) {
  return (
    <nav className="ops-console-rail" aria-label="Run attempts">
      <div className="ops-console-rail-heading">
        <span>Attempts</span>
        <small>{attempts.length} workers</small>
      </div>
      <div className="ops-console-attempt-list">
        {attempts.map((attempt, index) => {
          const isSelected = attempt.id === selected;
          const receipt = runReceipt(attempt, promoted === attempt.id);
          return (
            <button
              className="ops-console-attempt"
              data-state={attempt.state}
              data-receipt-state={receipt.state}
              data-selected={isSelected ? "true" : "false"}
              key={attempt.id}
              type="button"
              aria-pressed={isSelected}
              onClick={() => onSelect(attempt.id)}
            >
              <span className="ops-console-attempt-index" aria-hidden="true">
                {String(index + 1).padStart(2, "0")}
              </span>
              <span className="ops-console-attempt-copy">
                <strong>{attempt.label}</strong>
                <small>{attempt.direction}</small>
                <small className="ops-console-attempt-worker">{attempt.worker}</small>
              </span>
              <span className="ops-console-attempt-state" title={receipt.detail}>
                {receipt.label}
                {attached === attempt.id && <em>attached</em>}
              </span>
            </button>
          );
        })}
      </div>
      <div className="ops-console-rail-key" aria-label="Run receipt states">
        {Array.from(new Set(attempts.map((attempt) => runReceipt(attempt, promoted === attempt.id).state))).map((state) => (
          <span key={state} data-receipt-state={state}>{state}</span>
        ))}
      </div>
    </nav>
  );
}

function Preview({ attempt }: { attempt: RunAttempt }) {
  return (
    <article className="ops-console-preview" aria-label={`${attempt.label} preview`}>
      <header className="ops-console-panel-heading">
        <div>
          <span className="ops-console-kicker">LIVE PREVIEW</span>
          <strong>{attempt.direction}</strong>
        </div>
        <span className="ops-console-preview-chip">{attempt.state === "running" ? "Streaming" : "Captured"}</span>
      </header>
      <div className="ops-console-screen">
        <div className="ops-console-screen-topline">
          <span><b className="ops-console-screen-dot" /> atlas / workspace</span>
          <span>⌘ K&nbsp;&nbsp; · &nbsp;&nbsp;{attempt.id}</span>
        </div>
        <div className="ops-console-screen-body">
          <aside>
            <small>WORKSPACE</small>
            <span className="is-current">▣ &nbsp;Overview</span>
            <span>◫ &nbsp;Activity</span>
            <span>⌁ &nbsp;Projects</span>
            <span>⚙ &nbsp;Settings</span>
          </aside>
          <div className="ops-console-screen-main">
            <small>YOUR WORKSPACE</small>
            <h3>Make room for the work.</h3>
            <p>A quieter home for everything your team is building.</p>
            <div className="ops-console-screen-metrics">
              {[["IN PROGRESS", "12"], ["READY", "04"], ["SHIPPED", "28"]].map(([label, value]) => (
                <div key={label}>
                  <small>{label}</small>
                  <strong>{value}</strong>
                  <span />
                </div>
              ))}
            </div>
            <div className="ops-console-screen-activity">
              <span>Today</span>
              <p><b /> Refresh workspace navigation <small>Design</small></p>
              <p><b /> Improve the first run experience <small>Product</small></p>
            </div>
          </div>
        </div>
        <footer>fixture preview · worker output is isolated to {attempt.sessionId}</footer>
      </div>
    </article>
  );
}

function Evidence({ attempt }: { attempt: RunAttempt }) {
  return (
    <section className="ops-console-evidence" aria-label="Evidence detail">
      <header className="ops-console-panel-heading">
        <div>
          <span className="ops-console-kicker">EVIDENCE</span>
          <strong>Receipts and artifacts</strong>
        </div>
        <span className="ops-console-count">{attempt.artifacts.filter((artifact) => artifact.verified).length}/3</span>
      </header>
      <div className="ops-console-build" data-verdict={attempt.build}>
        <span className="ops-console-verdict" aria-hidden="true">{attempt.build === "passed" ? "✓" : attempt.build === "failed" ? "!" : "○"}</span>
        <div>
          <strong>Build {attempt.build}</strong>
          <small>{attempt.tests.passed} passed · {attempt.tests.failed} failed</small>
        </div>
      </div>
      <div className="ops-console-artifacts">
        {attempt.artifacts.length ? attempt.artifacts.map((artifact) => (
          <div className="ops-console-artifact" key={artifact.id}>
            <span aria-hidden="true">{artifact.kind === "recording" ? "▷" : artifact.kind === "patch" ? "±" : "▧"}</span>
            <div><strong>{artifact.name}</strong><small>{artifact.verified ? artifact.digest : "Awaiting verification"}</small></div>
            <b data-verdict={artifact.verified ? "passed" : "pending"}>{artifact.verified ? "✓" : "○"}</b>
          </div>
        )) : <p className="ops-console-empty">The worker will publish a screenshot, recording, and patch here.</p>}
      </div>
      <p className="ops-console-evidence-note">Artifacts are immutable and owned by this attempt.</p>
    </section>
  );
}

function Activity({ attempt }: { attempt: RunAttempt }) {
  return (
    <section className="ops-console-activity" aria-label="Agent activity">
      <header className="ops-console-panel-heading">
        <div><span className="ops-console-kicker">ACTIVITY</span><strong>Durable worker log</strong></div>
        <span className="ops-console-live-label"><i /> {attempt.state === "running" ? "LIVE" : "SAVED"}</span>
      </header>
      <div className="ops-console-activity-body">
        <p className="ops-console-activity-summary">{attempt.activity}</p>
        {attempt.rows.filter((row) => row.kind === "assistant" || row.kind === "activity").map((row) => (
          <div className="ops-console-log-entry" key={row.id}>
            <small>{row.kind === "assistant" ? "AGENT" : "TOOLS"}</small>
            <p>{row.text ?? row.items?.map((item) => item.text).join(" · ")}</p>
            {row.items?.map((item) => item.tool?.output && <pre key={item.tool.id}>{item.tool.output}</pre>)}
          </div>
        ))}
      </div>
    </section>
  );
}

export function OpsConsole({ snapshot, recovered, disconnected = false, client, onAttach, onAttachTicket, onApprove, pollMs = 4_000 }: OpsConsoleProps) {
  const [state, dispatch] = useReducer(reduceBoard, undefined, () => initialBoard(snapshot, disconnected));
  const [tab, setTab] = useState<"activity" | "preview">("preview");
  const [apiError, setApiError] = useState<string>();
  const [attachState, setAttachState] = useState<AttachState>("idle");
  const [actionPending, setActionPending] = useState<"attach" | "approve">();
  const stateRef = useRef(state);
  const apiSession = useRef<RunBoardApiSession | undefined>(undefined);
  const apiClient = useRef<RunApiClient | undefined>(undefined);
  stateRef.current = state;

  useEffect(() => {
    if (!client || apiClient.current === client) return;
    apiClient.current = client;
    apiSession.current = new RunBoardApiSession(snapshot.id, client);
  }, [client, snapshot.id]);

  const replay = useCallback(async () => {
    if (!client) {
      dispatch({ type: "receive", snapshot: recovered });
      return;
    }
    const session = apiSession.current;
    if (!session) return;
    try {
      setApiError(undefined);
      dispatch({ type: "receive", snapshot: await session.snapshotAndReplay() });
    } catch (error) {
      setApiError(error instanceof Error ? error.message : String(error));
    }
  }, [client, recovered]);

  useEffect(() => {
    if (!client || disconnected || !apiSession.current) return;
    let active = true;
    const refresh = async () => {
      const session = apiSession.current;
      if (!session || !active) return;
      try {
        const next = await session.replay(stateRef.current.snapshot);
        if (active) dispatch({ type: "receive", snapshot: next });
      } catch (error) {
        if (active) setApiError(error instanceof Error ? error.message : String(error));
      }
    };
    void refresh();
    const timer = pollMs > 0 ? setInterval(() => void refresh(), pollMs) : undefined;
    return () => {
      active = false;
      if (timer) clearInterval(timer);
    };
  }, [client, disconnected, pollMs]);

  const attempt = selectedAttempt(state);
  const approved = state.snapshot.attempts.find((item) => item.id === state.approval?.attemptId);
  const readyCount = state.snapshot.attempts.filter(evidenceReady).length;
  const attach = async () => {
    if (!attempt || state.connection !== "live" || actionPending) return;
    const intent: AttachTicketIntent = { runId: state.snapshot.id, attemptId: attempt.id, sessionId: attempt.sessionId, cursor: state.snapshot.cursor };
    try {
      setApiError(undefined);
      setAttachState("idle");
      setActionPending("attach");
      const ticket = onAttach ? await onAttach(intent) : client?.requestAttachTicket ? await client.requestAttachTicket(intent) : undefined;
      if (ticket && attachTicketExpired(ticket)) throw new RunApiHttpError(410, "This attach ticket has expired. Request a fresh ticket and try again.", "run_attach_expired");
      if (ticket) await (onAttachTicket ?? attachRunTerminal)(ticket);
      dispatch({ type: "attach", ...(ticket ? { ticket } : {}) });
      setAttachState(ticket ? "attached" : "idle");
    } catch (error) {
      setAttachState(attachFailureState(error));
      setApiError(error instanceof Error ? error.message : String(error));
    } finally {
      setActionPending(undefined);
    }
  };
  const approve = async () => {
    if (!attempt || actionPending) return;
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

  if (!attempt) return <main className="ops-console" data-connection={state.connection}><p>No attempts are available.</p></main>;
  const reviewed = Boolean(state.reviewed);
  const attachLabel = actionPending === "attach"
    ? "Attaching worker…"
    : state.attached === attempt.id
      ? "Worker attached"
      : attachState === "expired"
        ? "Attach expired · Retry"
        : attachState === "replayed"
          ? "Ticket used · Retry"
          : attachState === "error"
            ? "Attach failed · Retry"
            : "Attach worker terminal";
  return (
    <main className="ops-console" data-connection={state.connection} data-approved={state.approval?.attemptId ?? ""} data-attach-state={attachState} data-api-error={apiError ?? ""}>
      <header className="ops-console-header">
        <div className="ops-console-title">
          <span className="ops-console-eyebrow">RUN / {state.snapshot.id}</span>
          <h1>{state.snapshot.title}</h1>
          <p>{state.snapshot.source} <span>·</span> {state.snapshot.attempts.length} isolated workers <span>·</span> {readyCount} ready</p>
        </div>
        <div className="ops-console-connection" data-connection={state.connection} aria-live="polite">
          <span className="ops-console-connection-dot" />
          <strong>{state.connection === "live" ? "CONTROL PLANE LIVE" : "DISCONNECTED"}</strong>
          <small>event {state.snapshot.cursor}</small>
        </div>
      </header>
      <section className="ops-console-intent" aria-label="Shared intent">
        <div><span className="ops-console-kicker">SHARED INTENT</span><p>{state.snapshot.intent}</p></div>
        <span>same commit&nbsp; / &nbsp;separate sessions&nbsp; / &nbsp;durable events</span>
      </section>
      {state.connection === "disconnected" && (
        <section className="ops-console-reconnect" aria-live="polite">
          <div><strong>Workers are still running.</strong><span>Last saved cursor {state.snapshot.cursor} is safe to inspect.</span></div>
          <button type="button" onClick={() => void replay()}>Reconnect and replay</button>
        </section>
      )}
      {apiError && <p className="ops-console-error" role="alert">{apiError}</p>}
      <div className="ops-console-layout">
        <AttemptRail attempts={state.snapshot.attempts} selected={state.selected} attached={state.attached} promoted={state.approval?.attemptId} onSelect={(id) => dispatch({ type: "select", attemptId: id })} />
        <section className="ops-console-detail" aria-label="Selected attempt details">
          <header className="ops-console-detail-header">
            <div><span className="ops-console-kicker">SELECTED ATTEMPT</span><h2>{attempt.label}</h2><p>{attempt.worker} <span>·</span> {attempt.sessionId}</p></div>
            <div className="ops-console-detail-actions">
              <button type="button" className="ops-console-attach" disabled={state.connection !== "live" || Boolean(actionPending)} onClick={() => void attach()}>{attachLabel}<span aria-hidden="true">↗</span></button>
              <fieldset className="ops-console-tabs" aria-label="Selected attempt view">
                <button type="button" aria-pressed={tab === "preview"} onClick={() => setTab("preview")}>Preview</button>
                <button type="button" aria-pressed={tab === "activity"} onClick={() => setTab("activity")}>Activity</button>
              </fieldset>
            </div>
          </header>
          {(attachState === "expired" || attachState === "replayed") && <output className="ops-console-attach-status" aria-live="polite">{attachState === "expired" ? "The one-use ticket expired; retry to mint a fresh capability." : "The one-use ticket was already consumed; retry to mint a fresh capability."}</output>}
          {tab === "preview" ? <Preview attempt={attempt} /> : <Activity attempt={attempt} />}
          <Evidence attempt={attempt} />
          <footer className="ops-console-approval">
            <div><span className="ops-console-kicker">HUMAN GATE</span><strong>{state.approval ? "Integration review requested" : "Choose what moves forward"}</strong><p>{state.approval ? `${approved?.label ?? state.approval.attemptId} is queued with its evidence.` : "Review the preview, activity, and receipts before approving."}</p></div>
            <label><input type="checkbox" aria-label="I reviewed this attempt" checked={reviewed} disabled={!evidenceReady(attempt) || state.connection !== "live" || Boolean(state.approval)} onChange={(event) => dispatch({ type: "review", checked: event.currentTarget.checked })} /> reviewed</label>
            <button type="button" disabled={!state.reviewed || !evidenceReady(attempt) || state.connection !== "live" || Boolean(state.approval) || Boolean(actionPending)} onClick={() => void approve()}>{actionPending === "approve" ? "Recording…" : state.approval ? "Approval recorded" : "Approve candidate"}</button>
          </footer>
        </section>
      </div>
      <footer className="ops-console-footnote"><span>ops console · capture receipt: replay → select → attach → approve</span><span>cursor {state.snapshot.cursor}</span></footer>
    </main>
  );
}
