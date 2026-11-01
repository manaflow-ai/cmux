// The Agent Activity frame viewer: every screenshot the helper kept for a session, in order, one at
// a time. Previous and Next (and Left / Right, Home / End) step through them; the bar names the step
// that made the frame, its time and the position ("4 of 12"); the filmstrip under it shows every
// frame and opens one on a click. The split layout shows it inline; the timeline and grid open it
// over the page (FrameDialog). Frames load lazily through the host and stay bounded: the viewer
// keeps the shown frame and its two neighbours, the filmstrip only the thumbnails in view.
import { createContext, use, useEffect, useRef, useState } from "react";
import { Dialog } from "../ui/Dialog";
import { keyedIconProps } from "../ui/DialogButton";
import {
  displayFrame,
  frameEvents,
  frameIndex,
  frameWindow,
  positionText,
  selectedEvents,
  stepLabel,
  type ActivityEvent,
  type ActivityFrame,
  type ActivityFrameSize,
  type ActivitySession,
  type ActivityState,
} from "./model";

/** Reads one frame from the host as an image URL (`cmux.agentActivity.frame`). */
export type FrameLoader = (frame: ActivityFrame, size: ActivityFrameSize, session: string) => Promise<string>;

const FrameLoaderContext = createContext<FrameLoader>(() => Promise.reject(new Error("no frame loader")));
export const FrameLoaderProvider = FrameLoaderContext.Provider;

/** The frame step a key asks for: Left / Right one frame, Home / End the first or last; undefined for
 * any other key or a chord (those belong to the host). */
export function frameKeyStep(event: Pick<KeyboardEvent, "key" | "metaKey" | "ctrlKey" | "altKey">) {
  if (event.metaKey || event.ctrlKey || event.altKey) return undefined;
  if (event.key === "ArrowLeft") return -1;
  if (event.key === "ArrowRight") return 1;
  if (event.key === "Home") return -Infinity;
  if (event.key === "End") return Infinity;
  return undefined;
}

/** A key typed into a field, or one a control uses to move inside itself, is not a frame step. */
function ownsArrows(target: EventTarget | null): boolean {
  if (!(target instanceof Element)) return false;
  if (target instanceof HTMLElement && target.isContentEditable) return true;
  return (
    target.closest("input, textarea, select, [role=toolbar], [role=radiogroup], [role=listbox], [role=menu]") !== null
  );
}

const timeFormat = new Intl.DateTimeFormat(undefined, { hour: "numeric", minute: "2-digit", second: "2-digit" });
export const frameTime = (event: ActivityEvent) => timeFormat.format(new Date(event.time));

/** Whether `element` is in view of its scroller (always, where IntersectionObserver is missing). */
function useInView(): [(element: Element | null) => void, boolean] {
  const [element, setElement] = useState<Element | null>(null);
  const [inView, setInView] = useState(typeof IntersectionObserver === "undefined");
  useEffect(() => {
    if (!element || typeof IntersectionObserver === "undefined") return;
    // A margin past each edge, so a thumbnail is there by the time a scroll shows it.
    const observer = new IntersectionObserver((entries) => setInView(entries.some((entry) => entry.isIntersecting)), {
      rootMargin: "200px",
    });
    observer.observe(element);
    return () => observer.disconnect();
  }, [element]);
  return [setElement, inView];
}

/** Left / Right (Home / End) step the shown frames wherever focus is not in a field or a control that
 * moves with the arrows: in the split layout and in the dialog over the timeline or grid alike (only
 * one viewer is ever shown). A chord stays the host's. */
function useFrameKeys(step: (delta: number) => void) {
  const latest = useRef(step);
  latest.current = step;
  useEffect(() => {
    const onKey = (event: KeyboardEvent) => {
      const delta = frameKeyStep(event);
      if (delta === undefined || event.defaultPrevented || ownsArrows(event.target)) return;
      event.preventDefault();
      latest.current(delta);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, []);
}

/** A frame's image while `enabled`; dropped again when it is not (out of view). */
function useFrameImage(frame: ActivityFrame | undefined, size: ActivityFrameSize, session: string, enabled: boolean) {
  const load = use(FrameLoaderContext);
  const [image, setImage] = useState<{ key: string; src: string }>();
  const key = frame && !frame.expired && enabled ? `${session}|${size}|${frame.blob}` : undefined;
  useEffect(() => {
    if (!key || !frame) return;
    let live = true;
    load(frame, size, session).then(
      (src) => live && setImage({ key, src }),
      () => undefined,
    );
    return () => {
      live = false;
      setImage(undefined);
    };
    // oxlint-disable-next-line react-hooks/exhaustive-deps -- `key` names the frame, its size and its session.
  }, [key, load]);
  return image?.key === key ? image?.src : undefined;
}

/** The full frames of the window around `index` (frameWindow), by `session|blob`: each asked for once
 * while it is wanted (a quick run of steps does not ask again for a frame on its way), and dropped
 * when the viewer moves away from it. */
function useFrameWindow(frames: readonly ActivityEvent[], index: number, session: string): Map<string, string> {
  const load = use(FrameLoaderContext);
  const [images, setImages] = useState<Map<string, string>>(() => new Map());
  const wanted = frameWindow(frames, index).map((frame) => ({ frame, id: `${session}|${frame.blob}` }));
  const key = wanted.map((entry) => entry.id).join("\n");
  const wantedIDs = useRef<Set<string>>(new Set());
  const pending = useRef<Set<string>>(new Set());
  useEffect(() => {
    const ids = new Set(wanted.map((entry) => entry.id));
    wantedIDs.current = ids;
    setImages((current) => {
      const kept = new Map([...current].filter(([id]) => ids.has(id)));
      return kept.size === current.size ? current : kept;
    });
    for (const { frame, id } of wanted) {
      if (images.has(id) || pending.current.has(id)) continue;
      pending.current.add(id);
      load(frame, "full", session).then(
        (src) => {
          pending.current.delete(id);
          if (!wantedIDs.current.has(id)) return;
          setImages((current) => (current.get(id) === src ? current : new Map(current).set(id, src)));
        },
        () => pending.current.delete(id),
      );
    }
    // oxlint-disable-next-line react-hooks/exhaustive-deps -- `key` names every wanted frame and its session.
  }, [key, load]);
  return images;
}

function Chevron({ back }: { back?: boolean }) {
  return (
    <svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">
      <path d={back ? "M9.75 4.25 6 8l3.75 3.75" : "M6.25 4.25 10 8l-3.75 3.75"} />
    </svg>
  );
}

function CloseGlyph() {
  return (
    <svg viewBox="0 0 16 16" width="16" height="16" aria-hidden="true">
      <path d="m4.5 4.5 7 7m0-7-7 7" />
    </svg>
  );
}

/** A frame's thumbnail, loaded while it is in view. The caller supplies the button around it. */
export function FrameThumb({ event, session }: { event: ActivityEvent; session: string }) {
  const frame = displayFrame(event);
  const [ref, inView] = useInView();
  const src = useFrameImage(frame, "thumb", session, inView);
  const ratio = frame && frame.width > 0 && frame.height > 0 ? `${frame.width} / ${frame.height}` : undefined;
  return (
    <span ref={ref} className="thumb" style={{ aspectRatio: ratio }}>
      {src ? <img src={src} alt="" draggable={false} /> : null}
    </span>
  );
}

function Filmstrip({
  frames,
  index,
  session,
  strings,
  onPick,
}: {
  frames: readonly ActivityEvent[];
  index: number;
  session: string;
  strings: ActivityState["strings"];
  onPick(index: number): void;
}) {
  const current = useRef<HTMLButtonElement | null>(null);
  useEffect(() => {
    current.current?.scrollIntoView?.({ block: "nearest", inline: "nearest" });
  }, [index]);
  return (
    <div className="filmstrip">
      {frames.map((event, at) => (
        <button
          key={event.seq}
          type="button"
          ref={at === index ? current : undefined}
          className={`film ${event.ok ? "" : "bad"}`}
          aria-current={at === index || undefined}
          aria-label={`${stepLabel(event, strings)}, ${frameTime(event)}`}
          title={`${stepLabel(event, strings)} · ${frameTime(event)}`}
          onClick={() => onPick(at)}
        >
          <FrameThumb event={event} session={session} />
        </button>
      ))}
    </div>
  );
}

/** The viewer over the selected session: the frame, its bar, and the filmstrip. */
export function FrameViewer({
  state,
  dispatch,
  session,
  onClose,
}: {
  state: ActivityState;
  dispatch: (action: any) => void;
  session: ActivitySession;
  /** Shown over the page: a Close button in the bar (the dialog owns the keys). */
  onClose?: () => void;
}) {
  const strings = state.strings;
  const frames = frameEvents(selectedEvents(state));
  const index = frameIndex(state);
  const event = frames[index];
  const frame = event && displayFrame(event);
  const images = useFrameWindow(frames, index, session.id);
  const src = frame && images.get(`${session.id}|${frame.blob}`);
  const goTo = (target: number) => {
    const next = frames[Math.min(Math.max(target, 0), frames.length - 1)];
    if (next && next.seq !== event?.seq) dispatch({ type: "scrub", seq: next.seq });
  };
  const step = (delta: number) => goTo(index + delta);
  useFrameKeys(step);
  return (
    <div className="viewer" data-inline={!onClose || undefined}>
      <div className="viewer-stage">
        {!event ? (
          <span className="viewer-empty">{strings.noFrames}</span>
        ) : frame?.expired ? (
          <span className="viewer-empty">{strings.noFrame}</span>
        ) : src ? (
          <img src={src} alt={stepLabel(event, strings)} draggable={false} />
        ) : (
          <span className="viewer-loading" aria-busy="true" />
        )}
      </div>
      {(event || onClose) && (
        <div className="viewer-bar">
          <button
            type="button"
            className="viewer-button"
            disabled={index <= 0}
            {...keyedIconProps(strings.previous, "left")}
            onClick={() => step(-1)}
          >
            <Chevron back />
          </button>
          <button
            type="button"
            className="viewer-button"
            disabled={index < 0 || index >= frames.length - 1}
            {...keyedIconProps(strings.next, "right")}
            onClick={() => step(1)}
          >
            <Chevron />
          </button>
          {event && (
            <span className={`viewer-step ${event.ok ? "" : "bad"}`}>
              <b>{stepLabel(event, strings)}</b>
              {event.target ? <span>{event.target}</span> : null}
              <time dateTime={new Date(event.time).toISOString()}>{frameTime(event)}</time>
            </span>
          )}
          {frames.length > 0 && (
            <span className="viewer-position" aria-live="polite">
              {positionText(index, frames.length, strings)}
            </span>
          )}
          {onClose && (
            <button
              type="button"
              className="viewer-button"
              {...keyedIconProps(strings.close, "escape")}
              onClick={onClose}
            >
              <CloseGlyph />
            </button>
          )}
        </div>
      )}
      {frames.length > 1 && (
        <Filmstrip frames={frames} index={index} session={session.id} strings={strings} onPick={goTo} />
      )}
    </div>
  );
}

/** The viewer over the timeline or grid: a frame clicked there opens here; Escape or Close ends it. */
export function FrameDialog({
  state,
  dispatch,
  session,
}: {
  state: ActivityState;
  dispatch: (action: any) => void;
  session: ActivitySession;
}) {
  return (
    <Dialog
      open
      onOpenChange={(open) => {
        if (!open) dispatch({ type: "close" });
      }}
      label={`${session.agentName} · ${session.label}`}
      className="ui-glass activity-viewer-dialog"
    >
      <header className="activity-viewer-title">
        <span className="dot" style={{ background: session.colorHex }} />
        <strong>{session.agentName}</strong>
        <span>{session.label}</span>
      </header>
      <FrameViewer state={state} dispatch={dispatch} session={session} onClose={() => dispatch({ type: "close" })} />
    </Dialog>
  );
}
