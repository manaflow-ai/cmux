import { type KeyboardEvent, type ReactNode, type RefObject, useEffect, useRef, useState } from "react";
import { KeyboardScope } from "../../../ui/KeyboardScope";
import { AcpmuxDirectClient, type EventRecord } from "../direct";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import type { AcpmuxRow } from "../model";
import {
  clockLabel,
  continueSeq,
  REPLAY_SPEEDS,
  replayTimeline,
  seqAt,
  toolMark,
  type ReplayTimeline,
} from "./timeline";
import "./replay.css";

type Loaded = { client: AcpmuxDirectClient; timeline: ReplayTimeline };

/// How far the arrow keys move replay time.
const ARROW_STEP_MS = 5_000;

/// Shows replay time `time.current`: the transcript through that point, the scrubber's thumb,
/// (once a second) the clock, and the turn Continue from here would fork through.
function showAt(
  loaded: Loaded,
  time: RefObject<number>,
  scrub: RefObject<HTMLInputElement | null>,
  setSecond: (second: number) => void,
  setForkSeq: (seq: number | undefined) => void,
) {
  loaded.client.seekReplay(seqAt(loaded.timeline, time.current));
  if (scrub.current) scrub.current.value = String(Math.round(time.current));
  setSecond(Math.floor(time.current / 1000));
  setForkSeq(continueSeq(loaded.timeline, time.current));
}

/// A recorded chat played back read-only, as it happened (cx-osmw): its events fold into the
/// transcript on replay time (timeline.ts), with no composer and nothing sent to the agent.
/// Scrub with the bar, change speed, and jump between tool calls (also `[` and `]`). Continue from
/// here forks a live chat holding the conversation through the last turn finished at that point.
export function ReplayScreen({
  sessionId,
  title,
  load,
  onClose,
  onContinue,
  transcript,
}: {
  sessionId: string;
  title?: string;
  /** The session's recorded events (AcpmuxDirectClient.recordedEvents). */
  load: () => Promise<EventRecord[]>;
  onClose: () => void;
  /** Forks a live chat through the turn whose `turn_result` is `throughSeq`; absent when the chat
   * cannot be forked. */
  onContinue?: (throughSeq: number) => void;
  /** Draws the replayed rows; the pane passes its transcript. */
  transcript: (rows: AcpmuxRow[]) => ReactNode;
}) {
  const t = useT();
  const [loaded, setLoaded] = useState<Loaded | "loading" | "failed">("loading");
  const [rows, setRows] = useState<AcpmuxRow[]>([]);
  const [playing, setPlaying] = useState(true);
  const [speed, setSpeed] = useState<number>(1);
  // Replay time lives in a ref and the scrubber is uncontrolled: a frame moves both without a
  // render; the clock label re-renders once a second.
  const time = useRef(0);
  const scrub = useRef<HTMLInputElement>(null);
  const [second, setSecond] = useState(0);
  const [forkSeq, setForkSeq] = useState<number | undefined>();

  useEffect(() => {
    let live = true;
    setLoaded("loading");
    void load().then(
      (events) => {
        if (!live) return;
        const client = AcpmuxDirectClient.replay(sessionId, events, (snapshot) => live && setRows(snapshot.rows));
        time.current = 0;
        setLoaded({ client, timeline: replayTimeline(client.sessionEvents()) });
      },
      () => live && setLoaded("failed"),
    );
    return () => {
      live = false;
    };
  }, [sessionId, load]);

  const ready = typeof loaded === "object" ? loaded : undefined;
  useEffect(() => {
    if (!ready) return;
    showAt(ready, time, scrub, setSecond, setForkSeq);
    if (!playing) return;
    let last = performance.now();
    let frame = requestAnimationFrame(function tick(now) {
      time.current = Math.min(time.current + (now - last) * speed, ready.timeline.duration);
      last = now;
      showAt(ready, time, scrub, setSecond, setForkSeq);
      if (time.current >= ready.timeline.duration) setPlaying(false);
      // wakeup-allow: bounded the replay's timeline duration, or Pause
      else frame = requestAnimationFrame(tick);
    });
    return () => cancelAnimationFrame(frame);
  }, [ready, playing, speed]);

  const seek = (to: number) => {
    if (!ready) return;
    time.current = Math.min(Math.max(to, 0), ready.timeline.duration);
    showAt(ready, time, scrub, setSecond, setForkSeq);
  };
  const togglePlaying = () => {
    if (!ready) return;
    // Play at the end starts over.
    if (!playing && time.current >= ready.timeline.duration) seek(0);
    setPlaying(!playing);
  };
  const jump = (direction: "next" | "previous") => {
    const mark = ready && toolMark(ready.timeline, time.current, direction);
    if (mark) seek(mark.time);
  };
  const speeds: readonly number[] = REPLAY_SPEEDS;
  const nextSpeed = () => setSpeed(speeds[(speeds.indexOf(speed) + 1) % speeds.length]!);
  const onKeyDown = (event: KeyboardEvent) => {
    if (!ready || event.metaKey || event.ctrlKey || event.altKey) return;
    const target = event.target as HTMLElement;
    // A focused control keeps its own keys: Space and Enter press a button, arrows move the
    // scrubber, and a text field keeps every key.
    if (target.closest("textarea, select, [contenteditable]")) return;
    if (target.closest("button") && (event.key === " " || event.key === "Enter")) return;
    if (target.closest("input") && event.key.startsWith("Arrow")) return;
    const action: Record<string, () => void> = {
      " ": togglePlaying,
      ArrowLeft: () => seek(time.current - ARROW_STEP_MS),
      ArrowRight: () => seek(time.current + ARROW_STEP_MS),
      "[": () => jump("previous"),
      "]": () => jump("next"),
    };
    const run = action[event.key];
    if (!run) return;
    event.preventDefault();
    run();
  };
  // The keys act anywhere in the replay; each also has a button. Focus starts on Play.
  const play = useRef<HTMLButtonElement>(null);
  useEffect(() => {
    if (ready) play.current?.focus();
  }, [ready]);

  return (
    <KeyboardScope className="acpmux-replay" handleKeyDown={onKeyDown}>
      <header className="acpmux-replay-bar">
        <button type="button" className="acpmux-replay-button" aria-label={t("replay.back")} onClick={onClose}>
          <Icon name="nav.back" />
        </button>
        <span className="acpmux-replay-badge">{t("replay.badge")}</span>
        <span className="acpmux-replay-title">{title}</span>
        {ready && (
          <output className="acpmux-replay-clock">
            {clockLabel(second * 1000)} / {clockLabel(ready.timeline.duration)}
          </output>
        )}
      </header>
      {loaded === "loading" ? (
        <p className="acpmux-replay-note">{t("replay.loading")}</p>
      ) : loaded === "failed" ? (
        <p className="acpmux-replay-note" role="alert">
          {t("replay.failed")}
        </p>
      ) : loaded.timeline.steps.length === 0 ? (
        <p className="acpmux-replay-note">{t("replay.empty")}</p>
      ) : (
        <>
          {transcript(rows)}
          <div className="acpmux-replay-controls">
            <button
              type="button"
              className="acpmux-replay-button"
              aria-label={t("replay.previousTool")}
              title={t("replay.previousTool")}
              onClick={() => jump("previous")}
            >
              <Icon name="media.previous" />
            </button>
            <button
              ref={play}
              type="button"
              className="acpmux-replay-button"
              aria-label={playing ? t("replay.pause") : t("replay.play")}
              onClick={togglePlaying}
            >
              <Icon name={playing ? "media.pause" : "media.play"} />
            </button>
            <button
              type="button"
              className="acpmux-replay-button"
              aria-label={t("replay.nextTool")}
              title={t("replay.nextTool")}
              onClick={() => jump("next")}
            >
              <Icon name="media.next" />
            </button>
            <div className="acpmux-replay-track">
              <input
                ref={scrub}
                type="range"
                className="acpmux-replay-scrub"
                min={0}
                max={Math.max(loaded.timeline.duration, 1)}
                step={10}
                defaultValue={0}
                aria-label={t("replay.position")}
                aria-valuetext={clockLabel(second * 1000)}
                onInput={(event) => seek(Number(event.currentTarget.value))}
              />
              {loaded.timeline.tools.map((mark) => (
                <span
                  key={mark.seq}
                  className="acpmux-replay-tick"
                  aria-hidden="true"
                  title={mark.label}
                  style={{ left: `${(mark.time / Math.max(loaded.timeline.duration, 1)) * 100}%` }}
                />
              ))}
            </div>
            <button type="button" className="acpmux-replay-speed" aria-label={t("replay.speed")} onClick={nextSpeed}>
              {speed}×
            </button>
            {onContinue && (
              <button
                type="button"
                className="acpmux-replay-continue"
                disabled={forkSeq === undefined}
                onClick={() => forkSeq !== undefined && onContinue(forkSeq)}
              >
                {t("replay.continue")}
              </button>
            )}
          </div>
        </>
      )}
    </KeyboardScope>
  );
}
