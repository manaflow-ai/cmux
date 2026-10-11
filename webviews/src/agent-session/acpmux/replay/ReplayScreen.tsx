import { type ReactNode, useEffect, useRef, useState } from "react";
import { AcpmuxDirectClient, type EventRecord } from "../direct";
import { useT } from "../i18n";
import { Icon } from "../icons/Icon";
import type { AcpmuxRow } from "../model";
import { clockLabel, replayTimeline, seqAt, type ReplayTimeline } from "./timeline";
import "./replay.css";

type Loaded = { client: AcpmuxDirectClient; timeline: ReplayTimeline };

/// A recorded chat played back read-only, as it happened (cx-osmw): its events fold into the
/// transcript on replay time (timeline.ts), with no composer and nothing sent to the agent.
export function ReplayScreen({
  sessionId,
  title,
  load,
  onClose,
  transcript,
}: {
  sessionId: string;
  title?: string;
  /** The session's recorded events (AcpmuxDirectClient.recordedEvents). */
  load: () => Promise<EventRecord[]>;
  onClose: () => void;
  /** Draws the replayed rows; the pane passes its transcript. */
  transcript: (rows: AcpmuxRow[]) => ReactNode;
}) {
  const t = useT();
  const [loaded, setLoaded] = useState<Loaded | "loading" | "failed">("loading");
  const [rows, setRows] = useState<AcpmuxRow[]>([]);
  const [playing, setPlaying] = useState(true);
  // Replay time lives in a ref: the clock label re-renders once a second, not every frame.
  const time = useRef(0);
  const [second, setSecond] = useState(0);

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
    const show = () => {
      ready.client.seekReplay(seqAt(ready.timeline, time.current));
      setSecond(Math.floor(time.current / 1000));
    };
    show();
    if (!playing) return;
    let last = performance.now();
    let frame = requestAnimationFrame(function tick(now) {
      time.current = Math.min(time.current + (now - last), ready.timeline.duration);
      last = now;
      show();
      if (time.current >= ready.timeline.duration) setPlaying(false);
      else frame = requestAnimationFrame(tick);
    });
    return () => cancelAnimationFrame(frame);
  }, [ready, playing]);

  const togglePlaying = () => {
    if (!ready) return;
    // Play at the end starts over.
    if (!playing && time.current >= ready.timeline.duration) time.current = 0;
    setPlaying(!playing);
  };

  return (
    <div className="acpmux-replay">
      <header className="acpmux-replay-bar">
        <button type="button" className="acpmux-replay-button" aria-label={t("replay.back")} onClick={onClose}>
          <Icon name="nav.back" />
        </button>
        <span className="acpmux-replay-badge">{t("replay.badge")}</span>
        <span className="acpmux-replay-title">{title}</span>
        {ready && (
          <>
            <button
              type="button"
              className="acpmux-replay-button"
              aria-label={playing ? t("replay.pause") : t("replay.play")}
              onClick={togglePlaying}
            >
              <Icon name={playing ? "media.pause" : "media.play"} />
            </button>
            <output className="acpmux-replay-clock">
              {clockLabel(second * 1000)} / {clockLabel(ready.timeline.duration)}
            </output>
          </>
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
        transcript(rows)
      )}
    </div>
  );
}
