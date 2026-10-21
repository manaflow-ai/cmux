// The Agent Activity page's view: the header (title, filter, layout) over the split, timeline or
// grid of computer-use sessions. Pure over `state`; `dispatch` carries every user action to the
// page (main.tsx), which also tells the host. The gallery renders it over fixture states.
import { useEffect, useId, useState } from "react";
import {
  connectionText,
  currentEvent,
  currentFrameEvent,
  groups,
  selectedEvents,
  type ActivityEvent,
  type ActivitySession,
  type ActivityState,
} from "./model";
import { attentionCount, laneMachines, laneStatus } from "./lanes";
import { native } from "./native";

function Frame({ event, noFrame, onClick }: { event?: ActivityEvent; noFrame: string; onClick?: () => void }) {
  const frame = event && (event.afterFrame ?? event.beforeFrame);
  const [image, setImage] = useState<string>();
  useEffect(() => {
    let active = true;
    setImage(undefined);
    if (frame)
      native
        .request<string>("frame", { blob: frame.blob, width: frame.width, height: frame.height })
        .then((data) => {
          if (active) setImage(`data:image/png;base64,${data}`);
        })
        .catch(() => undefined);
    return () => {
      active = false;
    };
  }, [frame]);
  return (
    <button className="frame" onClick={onClick} disabled={!frame} title={frame ? undefined : noFrame}>
      {image ? <img src={image} alt="" /> : frame ? <span>…</span> : <span>⌁</span>}
    </button>
  );
}
function Status({ session, strings }: { session: ActivitySession; strings: ActivityState["strings"] }) {
  const live = typeof session.status === "string";
  const label =
    typeof session.status === "string" ? strings[session.status as "active" | "idle" | "paused"] : session.status.ended;
  return <span className={`status ${live ? "live" : ""}`}>{label}</span>;
}
function SessionRow({
  session,
  state,
  dispatch,
}: {
  session: ActivitySession;
  state: ActivityState;
  dispatch: (a: any) => void;
}) {
  return (
    <button
      className={`session ${session.id === state.selectedSessionID ? "selected" : ""}`}
      onClick={() => dispatch({ type: "select", id: session.id })}
    >
      <span className="dot" style={{ background: session.colorHex }} />
      <span className="session-text">
        <b>{session.agentName}</b>
        <small>
          {session.machineName} · {session.label}
        </small>
      </span>
      <Status session={session} strings={state.strings} />
    </button>
  );
}
function EventList({ state }: { state: ActivityState }) {
  return (
    <div className="events">
      {selectedEvents(state)
        .slice()
        .reverse()
        .map((event) => (
          <div className={`event selectable ${event.ok ? "" : "bad"}`} key={event.seq}>
            <span>
              {event.kind}
              {event.tool ? ` · ${event.tool}` : ""}
            </span>
            <small>#{event.seq}</small>
          </div>
        ))}
    </div>
  );
}
function Split({ state, dispatch }: { state: ActivityState; dispatch: (a: any) => void }) {
  const selected = Object.values(state.sessionsByMachine)
    .flat()
    .find((s) => s.id === state.selectedSessionID);
  const perform = (op: string, extra: Record<string, unknown> = {}) => {
    if (selected) native.request("perform", { op, session: selected.id, ...extra }).catch(() => undefined);
  };
  const events = selectedEvents(state);
  const scrub = (index: number | undefined) => {
    const seq = index === undefined ? undefined : events[Math.max(0, Math.min(events.length - 1, index))]?.seq;
    dispatch({ type: "scrub", seq });
  };
  return (
    <div className="split">
      <aside>
        <div className="groups">
          {groups(state).map((group) => (
            <section key={group.id}>
              <h3>{group.name}</h3>
              {connectionText(group.connection, state.strings) && (
                <p className="connection">{connectionText(group.connection, state.strings)}</p>
              )}
              {group.sessions.map((s) => (
                <SessionRow key={s.id} session={s} state={state} dispatch={dispatch} />
              ))}
            </section>
          ))}
        </div>
      </aside>
      <main className="detail">
        {selected ? (
          <>
            <header>
              <strong>{selected.label}</strong>
              <Status session={selected} strings={state.strings} />
              <span className="actions">
                <button onClick={() => perform("stop")}>{state.strings.stop}</button>
                <button
                  onClick={() =>
                    perform(typeof selected.status === "string" && selected.status === "paused" ? "resume" : "pause")
                  }
                >
                  {typeof selected.status === "string" && selected.status === "paused"
                    ? state.strings.resume
                    : state.strings.pause}
                </button>
                <button onClick={() => perform("watch", { on: !state.watching.includes(selected.id) })}>
                  {state.watching.includes(selected.id) ? state.strings.unwatch : state.strings.watch}
                </button>
              </span>
            </header>
            <div className="preview">
              <Frame event={currentFrameEvent(state)} noFrame={state.strings.noFrame} />
            </div>
            <div className="scrub">
              <button onClick={() => scrub(0)}>⏮</button>
              <button onClick={() => scrub((events.findIndex((e) => e.seq === currentEvent(state)?.seq) || 0) - 1)}>
                ◀
              </button>
              <button onClick={() => scrub((events.findIndex((e) => e.seq === currentEvent(state)?.seq) || 0) + 1)}>
                ▶
              </button>
              <button onClick={() => scrub(undefined)}>⏭</button>
            </div>
            <EventList state={state} />
          </>
        ) : (
          <Empty strings={state.strings} />
        )}
      </main>
    </div>
  );
}
function Timeline({ state, dispatch }: { state: ActivityState; dispatch: (a: any) => void }) {
  const sessions = groups(state).flatMap((g) => g.sessions);
  return (
    <div className="timeline">
      {sessions.map((session) => (
        <div className="lane" key={session.id}>
          <SessionRow session={session} state={state} dispatch={dispatch} />
          <div className="ticks">
            {(state.eventsBySession[session.id] ?? []).map((event) => (
              <Frame
                key={event.seq}
                event={event}
                noFrame={state.strings.noFrame}
                onClick={() => dispatch({ type: "scrub", seq: event.seq })}
              />
            ))}
          </div>
        </div>
      ))}
    </div>
  );
}
function Grid({ state, dispatch }: { state: ActivityState; dispatch: (a: any) => void }) {
  return (
    <div className="grid">
      {groups(state)
        .flatMap((g) => g.sessions)
        .map((session) => (
          <button className="tile" key={session.id} onClick={() => dispatch({ type: "select", id: session.id })}>
            <Frame event={(state.eventsBySession[session.id] ?? []).at(-1)} noFrame={state.strings.noFrame} />
            <b>{session.agentName}</b>
            <small>{session.label}</small>
          </button>
        ))}
    </div>
  );
}
function Empty({ strings }: { strings: ActivityState["strings"] }) {
  return (
    <div className="empty">
      <b>{strings.emptyTitle}</b>
      <span>{strings.emptyDetail}</span>
    </div>
  );
}

/** The lanes view (cx-v9k2f): every acpmux session by machine and coordinator; a click opens its chat. */
function Lanes({ state, dispatch }: { state: ActivityState; dispatch: (a: any) => void }) {
  const all = state.lanes ?? [];
  const machines = laneMachines(all, state.filter, state.strings);
  // The count is of every lane, as the sidebar's, whatever the filter hides.
  const attention = attentionCount(all);
  // "Idle · 3h" keeps counting on a quiet page: redraw each minute.
  const [now, setNow] = useState(Date.now);
  useEffect(() => {
    const timer = setInterval(() => setNow(Date.now()), 60_000);
    return () => clearInterval(timer);
  }, []);
  if (machines.length === 0) {
    return (
      <div className="lanes">
        <div className="empty">
          <b>{all.length ? state.strings.lanesNoMatch : state.strings.lanesEmpty}</b>
        </div>
      </div>
    );
  }
  return (
    <div className="lanes">
      {attention > 0 && (
        <p className="lanes-attention">{state.strings.lanesAttention.replace("{count}", String(attention))}</p>
      )}
      {machines.map((machine) => (
        <section key={machine.id} data-machine={machine.id}>
          <h2>{machine.name}</h2>
          {machine.groups.map((group) => (
            <div key={group.id} className="lane-group">
              <h3>{group.title}</h3>
              <ul>
                {group.lanes.map((lane) => (
                  <li key={lane.id}>
                    <button
                      className="lane"
                      data-lane={lane.id}
                      data-state={lane.state}
                      data-workspace={lane.workspaceId ?? undefined}
                      data-priority-revision={
                        state.priorityChangedSessionId === lane.id ? state.priorityRevision : undefined
                      }
                      /* tooltip-allow: the lane shows its title; the tooltip is when it started */
                      title={lane.since ? new Date(lane.since).toLocaleString() : undefined}
                      onClick={() =>
                        dispatch({ type: "jump", id: lane.id, workspaceId: lane.workspaceId ?? undefined })
                      }
                    >
                      <span className="lane-dot" />
                      <span className="lane-title">{lane.title}</span>
                      <span className="lane-status">{laneStatus(lane, now, state.strings)}</span>
                      {lane.error ? (
                        <span className="lane-error">{lane.error}</span>
                      ) : (
                        (lane.harness || lane.step) && (
                          <span className="lane-detail">
                            {lane.harness && <span className="lane-harness">{lane.harness}</span>}
                            {lane.step && <span className="lane-step">{lane.step}</span>}
                          </span>
                        )
                      )}
                    </button>
                  </li>
                ))}
              </ul>
            </div>
          ))}
        </section>
      ))}
    </div>
  );
}

/** A segmented control of native radios, as Settings draws them. */
function Segmented<T extends string>({
  label,
  className,
  value,
  options,
  onChange,
}: {
  label: string;
  className?: string;
  value: T;
  options: readonly (readonly [T, string])[];
  onChange: (value: T) => void;
}) {
  const name = useId();
  return (
    <fieldset className={className ? `segmented ${className}` : "segmented"} aria-label={label}>
      {options.map(([option, title]) => (
        <label key={option} className="segment" data-checked={value === option ? "" : undefined}>
          <input
            type="radio"
            name={name}
            value={option}
            aria-label={title}
            checked={value === option}
            onChange={() => onChange(option)}
          />
          {title}
        </label>
      ))}
    </fieldset>
  );
}

export function ActivityView({
  state,
  dispatch,
  error,
}: {
  state: ActivityState;
  dispatch: (a: any) => void;
  error?: string;
}) {
  const [page, setPage] = useState<"lanes" | "computer">("lanes");
  const showLanes = !!state.lanes && page === "lanes";
  const body =
    state.layout === "timeline" ? (
      <Timeline state={state} dispatch={dispatch} />
    ) : state.layout === "grid" ? (
      <Grid state={state} dispatch={dispatch} />
    ) : (
      <Split state={state} dispatch={dispatch} />
    );
  return (
    <div className="activity">
      <nav>
        <strong>{state.strings.title}</strong>
        {state.lanes && (
          <Segmented
            label={state.strings.pageView}
            className="page-view"
            value={page}
            options={[
              ["lanes", state.strings.lanes],
              ["computer", state.strings.computerUse],
            ]}
            onChange={setPage}
          />
        )}
        <input
          type="search"
          aria-label={state.strings.filter}
          placeholder={state.strings.filter}
          value={state.filter}
          onChange={(e) => dispatch({ type: "filter", value: e.target.value })}
        />
        {!showLanes && (
          <Segmented
            label={state.strings.layout}
            value={state.layout}
            options={[
              ["split", state.strings.layoutSplit],
              ["timeline", state.strings.layoutTimeline],
              ["grid", state.strings.layoutGrid],
            ]}
            onChange={(layout) => dispatch({ type: "layout", value: layout })}
          />
        )}
      </nav>
      {error ? <div className="error">{error}</div> : showLanes ? <Lanes state={state} dispatch={dispatch} /> : body}
    </div>
  );
}
