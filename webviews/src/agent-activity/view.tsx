// The Agent Activity page's view: the header (title, filter, layout) over the split, timeline or
// grid of computer-use sessions. Pure over `state`; `dispatch` carries every user action to the
// page (main.tsx), which also tells the host. The gallery renders it over fixture states.
// Screenshots go through the frame viewer (viewer.tsx): inline in the split, over the page from a
// frame clicked in the timeline or grid.
import { useId } from "react";
import {
  connectionText,
  currentFrameEvent,
  displayFrame,
  frameEvents,
  groups,
  selectedEvents,
  stepLabel,
  type ActivitySession,
  type ActivityState,
} from "./model";
import { native } from "./native";
import { FrameDialog, FrameLoaderProvider, FrameThumb, FrameViewer, frameTime, type FrameLoader } from "./viewer";

/** The host's bytes of a frame as a `data:` URL (AgentActivityRequests `frame`). */
const hostFrames: FrameLoader = (frame, size, session) =>
  native.request<string>("frame", { blob: frame.blob, width: frame.width, height: frame.height, size, session });

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
/** Every step of the session, newest first; a step with a screenshot opens it in the viewer. */
function EventList({ state, dispatch }: { state: ActivityState; dispatch: (a: any) => void }) {
  const shown = currentFrameEvent(state)?.seq;
  return (
    <div className="events">
      {selectedEvents(state)
        .slice()
        .reverse()
        .map((event) => {
          const text = (
            <>
              <span className="event-text">
                {stepLabel(event, state.strings)}
                {event.target ? <small>{event.target}</small> : null}
              </span>
              <small>{frameTime(event)}</small>
            </>
          );
          const className = `event ${event.ok ? "" : "bad"}`;
          return displayFrame(event) ? (
            <button
              type="button"
              className={className}
              key={event.seq}
              aria-current={event.seq === shown || undefined}
              onClick={() => dispatch({ type: "scrub", seq: event.seq })}
            >
              {text}
            </button>
          ) : (
            <div className={className} key={event.seq}>
              {text}
            </div>
          );
        })}
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
            <FrameViewer state={state} dispatch={dispatch} session={selected} />
            <EventList state={state} dispatch={dispatch} />
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
      {sessions.map((session) => {
        const frames = frameEvents(state.eventsBySession[session.id] ?? []);
        return (
          <div className="lane" key={session.id}>
            <SessionRow session={session} state={state} dispatch={dispatch} />
            <div className="ticks">
              {frames.length ? (
                frames.map((event) => (
                  <button
                    type="button"
                    className={`film ${event.ok ? "" : "bad"}`}
                    key={event.seq}
                    aria-label={`${stepLabel(event, state.strings)}, ${frameTime(event)}`}
                    title={`${stepLabel(event, state.strings)} · ${frameTime(event)}`}
                    onClick={() => dispatch({ type: "open", id: session.id, seq: event.seq })}
                  >
                    <FrameThumb event={event} session={session.id} />
                  </button>
                ))
              ) : (
                <small className="no-frames">{state.strings.noFrames}</small>
              )}
            </div>
          </div>
        );
      })}
    </div>
  );
}
function Grid({ state, dispatch }: { state: ActivityState; dispatch: (a: any) => void }) {
  return (
    <div className="grid">
      {groups(state)
        .flatMap((g) => g.sessions)
        .map((session) => {
          const latest = frameEvents(state.eventsBySession[session.id] ?? []).at(-1);
          return (
            <button
              type="button"
              className="tile"
              key={session.id}
              onClick={() => dispatch({ type: "open", id: session.id, seq: latest?.seq })}
            >
              <span className="tile-frame">
                {latest ? <FrameThumb event={latest} session={session.id} /> : <small>{state.strings.noFrames}</small>}
              </span>
              <b>{session.agentName}</b>
              <small>{session.label}</small>
            </button>
          );
        })}
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
  loadFrame = hostFrames,
}: {
  state: ActivityState;
  dispatch: (a: any) => void;
  error?: string;
  /** Where frames come from: the host by default; the gallery and tests pass their own. */
  loadFrame?: FrameLoader;
}) {
  const body =
    state.layout === "timeline" ? (
      <Timeline state={state} dispatch={dispatch} />
    ) : state.layout === "grid" ? (
      <Grid state={state} dispatch={dispatch} />
    ) : (
      <Split state={state} dispatch={dispatch} />
    );
  const viewing =
    state.viewing && state.layout !== "split"
      ? Object.values(state.sessionsByMachine)
          .flat()
          .find((session: ActivitySession) => session.id === state.selectedSessionID)
      : undefined;
  return (
    <FrameLoaderProvider value={loadFrame}>
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
        {viewing && !error && <FrameDialog state={state} dispatch={dispatch} session={viewing} />}
      </div>
    </FrameLoaderProvider>
  );
}
