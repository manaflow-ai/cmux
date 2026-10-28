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

/** A segmented control of native radios, as Settings draws them. */
function Segmented<T extends string>({
  label,
  value,
  options,
  onChange,
}: {
  label: string;
  value: T;
  options: readonly (readonly [T, string])[];
  onChange: (value: T) => void;
}) {
  const name = useId();
  return (
    <fieldset className="segmented" aria-label={label}>
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
        <input
          type="search"
          aria-label={state.strings.filter}
          placeholder={state.strings.filter}
          value={state.filter}
          onChange={(e) => dispatch({ type: "filter", value: e.target.value })}
        />
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
      </nav>
      {error ? <div className="error">{error}</div> : body}
    </div>
  );
}
