// l10n-allow-file: DEV gallery Run board timeline prototype, not shipped UI.
import { useCallback, useEffect, useMemo, useReducer, useRef, useState } from "react";
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
  type RunAttachTicket,
  type RunApiClient,
} from "../../runApi";
import { attachRunTerminal } from "../../runAttach";
import { attachTicketExpired } from "../../RunBoard";

export type TimelineRunBoardProps = {
  snapshot: RunBoardSnapshot;
  recovered?: RunBoardSnapshot;
  disconnected?: boolean;
  client?: RunApiClient;
  onAttach?: (intent: AttachTicketIntent) => Promise<RunAttachTicket | void>;
  onAttachTicket?: (ticket: RunAttachTicket) => Promise<void>;
  onApprove?: (intent: NonNullable<ReturnType<typeof reduceBoard>["approval"]>) => Promise<void>;
  pollMs?: number;
};

type TimelineEvent = {
  id: string;
  kind: "prompt" | "agent" | "tool" | "status";
  title: string;
  detail: string;
  status?: string;
  output?: string;
  seq?: number;
};

type AttachState = "idle" | "attached" | "expired" | "replayed" | "error";

function eventLabel(kind: TimelineEvent["kind"]): string {
  if (kind === "prompt") return "Prompt";
  if (kind === "agent") return "Agent";
  if (kind === "tool") return "Tool";
  return "Run status";
}

function eventsFor(attempt: RunAttempt): TimelineEvent[] {
  return attempt.rows.flatMap<TimelineEvent>((row, rowIndex): TimelineEvent[] => {
    const items = row.items ?? [];
    if (items.length > 0) {
      return items.map((item, itemIndex) => ({
        id: `${attempt.id}-${row.id}-${item.tool?.id ?? itemIndex}`,
        kind: "tool" as const,
        title: item.tool?.title ?? item.text,
        detail: item.tool?.inputSummary ?? item.text,
        status: item.tool?.status ?? row.status,
        output: item.tool?.output,
        seq: row.seq,
      }));
    }
    const kind: TimelineEvent["kind"] = row.kind === "user" ? "prompt" : row.kind === "assistant" ? "agent" : "status";
    const detail = row.text?.trim() || (row.error ? row.error : "Recorded activity");
    return [
      {
        id: `${attempt.id}-${row.id}`,
        kind,
        title: kind === "prompt" ? "Shared intent received" : kind === "agent" ? "Agent update" : "Run event",
        detail,
        status: row.failed ? "failed" : row.pending || row.streaming ? "running" : row.status,
        seq: row.seq ?? (rowIndex > 0 ? undefined : undefined),
      },
    ];
  });
}

function shortDigest(digest: string): string {
  if (digest.length <= 28) return digest;
  return `${digest.slice(0, 12)}…${digest.slice(-10)}`;
}

function statusText(attempt: RunAttempt): string {
  if (attempt.state === "completed") return "Ready to compare";
  if (attempt.state === "failed") return "Needs attention";
  return "Working";
}

function AttemptFilmstrip({
  attempts,
  selected,
  onSelect,
}: {
  attempts: RunAttempt[];
  selected: string;
  onSelect: (attemptId: string) => void;
}) {
  return (
    <nav className="timeline-filmstrip" aria-label="Run attempts">
      <div className="timeline-filmstrip-heading">
        <span>Attempts</span>
        <small>{attempts.length} independent paths</small>
      </div>
      <div className="timeline-filmstrip-list">
        {attempts.map((attempt, index) => {
          const files = sessionSummary(attempt.rows).outputs.length;
          const verified = attempt.artifacts.filter((artifact) => artifact.verified).length;
          return (
            <button
              className="timeline-filmstrip-item"
              key={attempt.id}
              type="button"
              aria-pressed={selected === attempt.id}
              data-attempt={attempt.id}
              data-state={attempt.state}
              onClick={() => onSelect(attempt.id)}
            >
              <span className="timeline-filmstrip-index">{String(index + 1).padStart(2, "0")}</span>
              <span className="timeline-filmstrip-copy">
                <strong>{attempt.label}</strong>
                <span>{attempt.direction}</span>
                <small>Provider / placement · {attempt.worker}</small>
              </span>
              <span className="timeline-filmstrip-state">{statusText(attempt)}</span>
              <span className="timeline-filmstrip-metrics">
                <span>{attempt.tests.passed} tests</span>
                <span>{verified}/3 evidence</span>
                <span>{files} files</span>
              </span>
            </button>
          );
        })}
      </div>
    </nav>
  );
}

function ReplayCursor({
  cursor,
  eventCount,
  connection,
}: {
  cursor: string;
  eventCount: number;
  connection: "live" | "disconnected";
}) {
  const numericCursor = Number(cursor);
  const progress =
    Number.isFinite(numericCursor) && numericCursor > 0
      ? Math.min(100, Math.max(8, (eventCount / numericCursor) * 100))
      : 100;
  return (
    <section className="timeline-cursor-panel" aria-label="Replay cursor">
      <div className="timeline-cursor-heading">
        <span>Replay cursor</span>
        <output data-replay-cursor={`event-${cursor}`}>Event {cursor}</output>
      </div>
      <div className="timeline-cursor-track" aria-label={`Replay cursor is at event ${cursor}`}>
        <span className="timeline-cursor-fill" style={{ width: `${progress}%` }} />
        <span className="timeline-cursor-pin" style={{ left: `${progress}%` }} />
      </div>
      <div className="timeline-cursor-meta">
        <span>{connection === "live" ? "Owner events are current" : "Last durable event saved locally"}</span>
        <span>{eventCount} visible activity records</span>
      </div>
    </section>
  );
}

function TimelineStream({ attempt, cursor }: { attempt: RunAttempt; cursor: string }) {
  const events = useMemo(() => eventsFor(attempt), [attempt]);
  return (
    <section className="timeline-stream" aria-label={`${attempt.label} activity timeline`}>
      <div className="timeline-section-heading">
        <div>
          <span className="timeline-kicker">Durable activity</span>
          <h2>What happened</h2>
        </div>
        <span className="timeline-stream-count">{events.length} records</span>
      </div>
      <ol className="timeline-events">
        {events.map((event, index) => (
          <li className="timeline-event" key={event.id} data-event-index={index}>
            <span className={`timeline-event-marker timeline-event-marker-${event.kind}`} aria-hidden="true">
              {event.kind === "prompt" ? "→" : event.kind === "agent" ? "✦" : event.kind === "tool" ? "∙" : "·"}
            </span>
            <div className="timeline-event-body">
              <div className="timeline-event-head">
                <span className="timeline-event-kind">{eventLabel(event.kind)}</span>
                <span className="timeline-event-sequence">
                  {event.seq ? `Event ${event.seq}` : `Record ${String(index + 1).padStart(2, "0")}`}
                </span>
              </div>
              <strong>{event.title}</strong>
              <p>{event.detail}</p>
              {event.output && <pre>{event.output}</pre>}
              {event.status && (
                <span className={`timeline-event-status timeline-event-status-${event.status}`}>{event.status}</span>
              )}
            </div>
          </li>
        ))}
      </ol>
      <p className="timeline-stream-receipt">
        This activity is replayed from the run owner at cursor {cursor}; it remains available after a worker disconnect.
      </p>
    </section>
  );
}

function SelectedPreview({ attempt }: { attempt: RunAttempt }) {
  return (
    <div
      className="timeline-preview"
      data-preview-attempt={attempt.id}
      aria-label={`${attempt.label} selected attempt preview`}
    >
      <div className="timeline-preview-chrome">
        <span>
          <i /> <i /> <i />
        </span>
        <small>{attempt.label.toLowerCase().replaceAll(" ", "-")}.workspace</small>
        <span>⌘ K</span>
      </div>
      <div className="timeline-preview-content">
        <aside>
          <strong>atlas</strong>
          <span className="is-active">Overview</span>
          <span>Activity</span>
          <span>Projects</span>
          <span>Settings</span>
        </aside>
        <div>
          <small>YOUR WORKSPACE</small>
          <h3>Make room for the work.</h3>
          <p>A quieter home for everything your team is building.</p>
          <div className="timeline-preview-grid">
            {["In progress", "Ready for review", "Recently shipped"].map((label, index) => (
              <div key={label}>
                <span>{label}</span>
                <strong>{[12, 4, 28][index]}</strong>
                <i />
                <i />
              </div>
            ))}
          </div>
          <div className="timeline-preview-row">
            <span>Today</span>
            <b>Refresh workspace navigation</b>
            <small>Design</small>
          </div>
          <div className="timeline-preview-row">
            <span>Tomorrow</span>
            <b>Improve first run experience</b>
            <small>Product</small>
          </div>
        </div>
      </div>
      <span className="timeline-preview-caption">Selected attempt preview · captured by {attempt.worker}</span>
    </div>
  );
}

function Provenance({ attempt, cursor }: { attempt: RunAttempt; cursor: string }) {
  return (
    <section className="timeline-provenance" aria-label="Artifact provenance">
      <div className="timeline-section-heading">
        <div>
          <span className="timeline-kicker">Evidence chain</span>
          <h2>Artifact provenance</h2>
        </div>
        <span className="timeline-provenance-count">
          {attempt.artifacts.filter((artifact) => artifact.verified).length}/3 verified
        </span>
      </div>
      <p className="timeline-provenance-intro">Every file stays attributed to this attempt and its worker session.</p>
      <div className="timeline-artifacts">
        {attempt.artifacts.map((artifact) => (
          <div className="timeline-artifact" key={artifact.id} data-artifact={artifact.id}>
            <span className="timeline-artifact-icon" aria-hidden="true">
              {artifact.kind === "recording" ? "▷" : artifact.kind === "patch" ? "±" : "▧"}
            </span>
            <div>
              <strong>{artifact.name}</strong>
              <span>{artifact.verified ? "Digest verified" : "Awaiting verification"}</span>
              <small>{shortDigest(artifact.digest)}</small>
              <small>
                Source: {attempt.worker} · {attempt.sessionId} · Event {cursor}
              </small>
            </div>
            <b data-verdict={artifact.verified ? "passed" : "pending"}>{artifact.verified ? "✓" : "○"}</b>
          </div>
        ))}
      </div>
      {attempt.artifacts.length === 0 && (
        <p className="timeline-empty-evidence">
          The worker has not published evidence yet. It will appear here when the owner replays the next event.
        </p>
      )}
    </section>
  );
}

export function TimelineRunBoard({
  snapshot,
  recovered = snapshot,
  disconnected = false,
  client,
  onAttach,
  onAttachTicket,
  onApprove,
  pollMs = 0,
}: TimelineRunBoardProps) {
  const [state, dispatch] = useReducer(reduceBoard, undefined, () => initialBoard(snapshot, disconnected));
  const [attachState, setAttachState] = useState<AttachState>("idle");
  const [pending, setPending] = useState<"attach" | "approve">();
  const [error, setError] = useState<string>();
  const session = useRef<RunBoardApiSession | undefined>(undefined);
  const activeClient = useRef<RunApiClient | undefined>(undefined);
  const stateRef = useRef(state);
  stateRef.current = state;

  useEffect(() => {
    if (!client || activeClient.current === client) return;
    activeClient.current = client;
    session.current = new RunBoardApiSession(snapshot.id, client);
  }, [client, snapshot.id]);

  const replay = useCallback(async () => {
    try {
      setError(undefined);
      if (!client) {
        dispatch({ type: "receive", snapshot: recovered });
        return;
      }
      const next = await session.current?.snapshotAndReplay();
      if (next) dispatch({ type: "receive", snapshot: next });
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
    }
  }, [client, recovered]);

  useEffect(() => {
    if (!client || disconnected || !session.current || pollMs <= 0) return;
    const timer = setInterval(() => {
      void session.current
        ?.replay(stateRef.current.snapshot)
        .then((next) => dispatch({ type: "receive", snapshot: next }))
        .catch((cause) => setError(cause instanceof Error ? cause.message : String(cause)));
    }, pollMs);
    return () => clearInterval(timer);
  }, [client, disconnected, pollMs]);

  const attempt = selectedAttempt(state);
  const events = useMemo(() => (attempt ? eventsFor(attempt) : []), [attempt]);
  const reviewed = Boolean(state.reviewed);
  const approved = state.snapshot.attempts.find((item) => item.id === state.approval?.attemptId);
  const readyCount = state.snapshot.attempts.filter((item) => evidenceReady(item)).length;

  const attach = async () => {
    if (!attempt || state.connection !== "live" || pending) return;
    const intent: AttachTicketIntent = {
      runId: state.snapshot.id,
      attemptId: attempt.id,
      sessionId: attempt.sessionId,
      cursor: state.snapshot.cursor,
    };
    try {
      setPending("attach");
      setAttachState("idle");
      setError(undefined);
      const ticket = onAttach
        ? await onAttach(intent)
        : client?.requestAttachTicket
          ? await client.requestAttachTicket(intent)
          : undefined;
      if (ticket && attachTicketExpired(ticket))
        throw new RunApiHttpError(
          410,
          "This attach ticket has expired. Request a fresh ticket and try again.",
          "run_attach_expired",
        );
      if (ticket) await (onAttachTicket ?? attachRunTerminal)(ticket);
      dispatch({ type: "attach", ...(ticket ? { ticket } : {}) });
      setAttachState(ticket ? "attached" : "idle");
    } catch (cause) {
      const status = cause instanceof RunApiHttpError ? cause.status : 0;
      const code = cause instanceof RunApiHttpError ? (cause.code ?? "") : "";
      setAttachState(
        status === 410 || code.includes("expire")
          ? "expired"
          : status === 409 && (code.includes("replay") || code.includes("consum"))
            ? "replayed"
            : "error",
      );
      setError(cause instanceof Error ? cause.message : String(cause));
    } finally {
      setPending(undefined);
    }
  };

  const approve = async () => {
    if (!canApprove(state) || pending) return;
    const candidate = reduceBoard(state, { type: "approve" }).approval;
    if (!candidate) return;
    try {
      setPending("approve");
      setError(undefined);
      await onApprove?.(candidate);
      dispatch({ type: "approve" });
    } catch (cause) {
      setError(cause instanceof Error ? cause.message : String(cause));
    } finally {
      setPending(undefined);
    }
  };

  return (
    <main
      className="timeline-board"
      data-connection={state.connection}
      data-approved={state.approval?.attemptId ?? ""}
      data-attach-state={attachState}
      data-api-error={error ?? ""}
    >
      <header className="timeline-header">
        <div>
          <div className="timeline-eyebrow">
            <span>RUN {state.snapshot.id}</span>
            <i /> <span>chronological review</span>
          </div>
          <h1>{state.snapshot.title}</h1>
          <p>
            {state.snapshot.source} <i /> {state.snapshot.attempts.length} independent attempts <i /> {readyCount} ready
            to compare
          </p>
        </div>
        <div className="timeline-connection" data-connection-label={state.connection}>
          <span className="timeline-connection-dot" />
          <strong>{state.connection === "live" ? "Live" : "Disconnected"}</strong>
          <small>Owner event {state.snapshot.cursor}</small>
        </div>
      </header>

      <section className="timeline-intent" aria-label="Shared intent">
        <span className="timeline-kicker">Shared intent</span>
        <div>
          <p>{state.snapshot.intent}</p>
          <small>{state.snapshot.source} · Same starting commit · Separate workspaces</small>
        </div>
      </section>

      {state.connection === "disconnected" && (
        <section className="timeline-recovery" aria-live="polite" data-recovery="available">
          <span className="timeline-recovery-icon" aria-hidden="true">
            ↻
          </span>
          <div>
            <strong>Disconnected after event {state.snapshot.cursor}</strong>
            <p>Your workers are retained. The board is showing the last durable activity and evidence.</p>
          </div>
          <button
            type="button"
            onClick={() => void replay()}
            aria-label={`Reconnect and replay from saved event ${state.snapshot.cursor}`}
          >
            Reconnect and replay
          </button>
        </section>
      )}
      {error && (
        <p className="timeline-error" role="alert">
          {error}
        </p>
      )}

      <AttemptFilmstrip
        attempts={state.snapshot.attempts}
        selected={state.selected}
        onSelect={(attemptId) => dispatch({ type: "select", attemptId })}
      />

      {attempt && (
        <>
          <ReplayCursor cursor={state.snapshot.cursor} eventCount={events.length} connection={state.connection} />
          <section className="timeline-workspace" aria-label="Selected attempt review">
            <header className="timeline-workspace-header">
              <div>
                <span className="timeline-kicker">Selected attempt</span>
                <h2>{attempt.label}</h2>
                <p>
                  {attempt.direction} · Provider / placement: {attempt.worker} · {attempt.sessionId}
                </p>
              </div>
              <button
                className="timeline-attach"
                type="button"
                disabled={state.connection !== "live" || pending === "attach"}
                onClick={() => void attach()}
              >
                {pending === "attach"
                  ? "Attaching…"
                  : state.attached === attempt.id
                    ? "Worker terminal attached"
                    : attachState === "expired"
                      ? "Attach expired · Retry"
                      : attachState === "replayed"
                        ? "Attach used · Retry"
                        : attachState === "error"
                          ? "Attach failed · Retry"
                          : "Attach worker terminal"}
                <span aria-hidden="true">↗</span>
              </button>
            </header>
            {(attachState === "expired" || attachState === "replayed" || attachState === "error") && (
              <p className="timeline-attach-status" role={attachState === "error" ? "alert" : "status"}>
                {attachState === "expired"
                  ? "The one-use ticket expired. Requesting a fresh ticket is safe."
                  : attachState === "replayed"
                    ? "That ticket was already consumed. Request a fresh ticket to reconnect."
                    : "The worker session could not be attached. Try again while it is retained."}
              </p>
            )}
            <div className="timeline-review-grid">
              <TimelineStream attempt={attempt} cursor={state.snapshot.cursor} />
              <div className="timeline-preview-column">
                <SelectedPreview attempt={attempt} />
                <Provenance attempt={attempt} cursor={state.snapshot.cursor} />
              </div>
            </div>
            <footer className="timeline-approval">
              <div>
                <span className="timeline-kicker">Human decision</span>
                <strong>{state.approval ? "Integration intent recorded" : "Choose what moves forward"}</strong>
                <p>
                  {state.approval
                    ? `${approved?.label ?? state.approval.attemptId} is queued for a separate integration review.`
                    : "Review the event story, preview and provenance before approving this candidate."}
                </p>
              </div>
              <label>
                <input
                  type="checkbox"
                  aria-label="I reviewed this attempt"
                  checked={reviewed}
                  disabled={!evidenceReady(attempt) || state.connection !== "live" || Boolean(state.approval)}
                  onChange={(event) => dispatch({ type: "review", checked: event.currentTarget.checked })}
                />{" "}
                I reviewed this attempt
              </label>
              <button
                type="button"
                disabled={!canApprove(state) || pending === "approve"}
                onClick={() => void approve()}
              >
                {pending === "approve"
                  ? "Recording approval…"
                  : state.approval
                    ? "Approval recorded"
                    : "Approve for integration"}
              </button>
            </footer>
          </section>
        </>
      )}

      <footer className="timeline-footnote">
        <span>Timeline variant · Interactive prototype</span>
        <span>Intent → activity → evidence → human selection</span>
      </footer>
    </main>
  );
}
