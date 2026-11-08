// The capture bar (captureModel.ts; plans/cmux-next/capture-bar-DESIGN.md): a band over the composer,
// in the composer hat's glass, that the Capture shortcut (⌃⇧⌘5) or View > Capture… opens on the chat
// the person is working in. Leo, 2026-11-07: "could we also have a more native
// screenshot/screensharer (ergonomic one)/video recording of the app type thing/route?"
//
// One click does one thing: a target takes the screenshot, Record starts filming the cmux window,
// Stop ends it. Where the result goes (the chat, the clipboard, a file) is one choice beside them,
// kept for the next capture. While it records, the band is the timer and Stop; the shortcut stops
// it too.
//
// One state transition (design/motion.md): the band's height eases on --agent-motion-move with the
// stack under it as it opens, turns into the recording line and leaves, and the content crossfades
// on the same clock; with motion off every change is one frame. Arms in captureBar.experiment.ts.
import React, { type CSSProperties, useEffect, useLayoutEffect, useRef, useState } from "react";
import { experimentArm } from "../../../experiments/experiment";
import { useT, type StringKey } from "../i18n";
import { Icon } from "../icons/Icon";
import { captureBarLook, type CaptureBarLook } from "./captureBar.experiment";
import {
  CAPTURE_DESTINATIONS,
  CAPTURE_TARGETS,
  elapsedLabel,
  type CaptureDestination,
  type CaptureState,
  type CaptureTarget,
} from "./captureModel";
import "./captureBar.css";

const TARGET_KEY: Record<CaptureTarget, StringKey> = {
  screen: "capture.target.region",
  window: "capture.target.window",
  pane: "capture.target.pane",
  app: "capture.target.app",
};
const DESTINATION_KEY: Record<CaptureDestination, StringKey> = {
  chat: "capture.destination.chat",
  copy: "capture.destination.copy",
  save: "capture.destination.save",
};

export type CaptureBarActions = {
  shoot(target: CaptureTarget): void;
  record(): void;
  stop(): void;
  close(): void;
  destination(destination: CaptureDestination): void;
  option(option: "cursor" | "clicks", on: boolean): void;
};

/// The recording's length, once a second while it records and never after (the interval's stop
/// condition is the phase).
function useElapsed(startedAt: number | undefined, now: () => number): string {
  const [, tick] = useState(0);
  useEffect(() => {
    if (startedAt === undefined) return;
    const timer = setInterval(() => tick((count) => count + 1), 1000);
    return () => clearInterval(timer);
  }, [startedAt]);
  return startedAt === undefined ? "" : elapsedLabel(now() - startedAt);
}

export function CaptureBar({
  state,
  actions,
  look: lookProp,
  now = Date.now,
}: {
  state: CaptureState;
  actions: CaptureBarActions;
  /// The gallery's arm; the pane reads the experiment.
  look?: CaptureBarLook;
  now?: () => number;
}) {
  const t = useT();
  const [armRead] = useState(() => experimentArm(captureBarLook));
  const look = lookProp ?? armRead;
  const open = state.phase.kind !== "closed";
  // What is drawn: the phase, or while the band leaves, the last open one, so nothing pops out.
  const [keptPhase, setKeptPhase] = useState(state.phase);
  if (open && keptPhase !== state.phase) setKeptPhase(state.phase);
  const leaving = !open && keptPhase.kind !== "closed";
  const phase = open ? state.phase : keptPhase;
  const recording = phase.kind === "recording" || phase.kind === "finishing";
  const busy = phase.kind === "busy" ? phase.what : undefined;
  const elapsed = useElapsed(phase.kind === "recording" ? phase.startedAt : undefined, now);
  // The segmented arm picks a mode first, then Capture.
  const [mode, setMode] = useState<"shot" | "record">("shot");
  const [target, setTarget] = useState<CaptureTarget>("screen");

  // The band's height follows its content's, eased; zero while closed. Already open when it mounts
  // (a chat switch mounts it again), it draws at its height at once.
  const inner = useRef<HTMLDivElement>(null);
  const [height, setHeight] = useState(0);
  const [settled, setSettled] = useState(false);
  useEffect(() => {
    const frame = requestAnimationFrame(() => setSettled(true));
    return () => cancelAnimationFrame(frame);
  }, []);
  useLayoutEffect(() => {
    const element = inner.current;
    if (!open || !element) return;
    const measure = () => setHeight(element.offsetHeight);
    measure();
    const observer = new ResizeObserver(measure);
    observer.observe(element);
    return () => observer.disconnect();
  }, [open]);
  // The first frame of an opening draws at zero, the next eases to the content's.
  const [arrived, setArrived] = useState(open);
  useEffect(() => {
    if (!open) {
      setArrived(false);
      return;
    }
    const frame = requestAnimationFrame(() => setArrived(true));
    return () => cancelAnimationFrame(frame);
  }, [open]);
  // Leaving: the last content stays until the height reaches zero, then goes in the same frame
  // (at once with motion off, where no transition runs).
  const outer = useRef<HTMLDivElement>(null);
  const done = () => setKeptPhase({ kind: "closed" });
  useLayoutEffect(() => {
    if (leaving && !outer.current?.getAnimations().some((animation) => animation.playState === "running"))
      setKeptPhase({ kind: "closed" });
  }, [leaving]);
  // Esc closes the bar from anywhere in the pane while it is open and not recording.
  useEffect(() => {
    if (state.phase.kind !== "open") return;
    const onKey = (event: KeyboardEvent) => {
      if (event.key !== "Escape" || event.defaultPrevented) return;
      event.preventDefault();
      actions.close();
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [state.phase.kind, actions]);

  const waiting = busy !== undefined;
  const targetButton = (each: CaptureTarget) => (
    <button
      key={each}
      type="button"
      className="acpmux-capture__target"
      data-target={each}
      data-busy={busy === each || undefined}
      data-picked={(look === "segmented" && target === each) || undefined}
      disabled={waiting}
      title={look === "chip" ? t(TARGET_KEY[each]) : undefined}
      aria-label={look === "chip" ? t(TARGET_KEY[each]) : undefined}
      onClick={() => (look === "segmented" ? setTarget(each) : actions.shoot(each))}
    >
      {look === "chip" ? (
        <span className="acpmux-capture__glyph" data-target={each} aria-hidden="true" />
      ) : (
        t(TARGET_KEY[each])
      )}
    </button>
  );
  const options = (
    <span className="acpmux-capture__options">
      {(["cursor", "clicks"] as const).map((option) => (
        <label key={option} className="acpmux-capture__option">
          <input
            type="checkbox"
            aria-label={t(option === "cursor" ? "capture.option.cursor" : "capture.option.clicks")}
            checked={state[option]}
            disabled={waiting}
            onChange={(event) => actions.option(option, event.target.checked)}
          />
          {t(option === "cursor" ? "capture.option.cursor" : "capture.option.clicks")}
        </label>
      ))}
    </span>
  );
  const recordButton = (
    <button
      type="button"
      className="acpmux-capture__record"
      data-busy={busy === "record" || undefined}
      disabled={waiting}
      title={look === "chip" ? t("capture.record") : undefined}
      aria-label={look === "chip" ? t("capture.record") : undefined}
      onClick={actions.record}
    >
      <span className="acpmux-capture__dot" aria-hidden="true" />
      {look !== "chip" && t("capture.record")}
    </button>
  );
  const destinations = (
    <fieldset className="acpmux-capture__destinations" aria-label={t("capture.destination")}>
      {CAPTURE_DESTINATIONS.map((each) => (
        <button
          key={each}
          type="button"
          aria-pressed={state.destination === each}
          className="acpmux-capture__destination"
          disabled={waiting}
          onClick={() => actions.destination(each)}
        >
          {t(DESTINATION_KEY[each])}
        </button>
      ))}
    </fieldset>
  );
  const close = (
    <button
      type="button"
      className="acpmux-capture__close"
      aria-label={t("capture.close")}
      title={t("capture.close")}
      onClick={actions.close}
    >
      <Icon name="action.close" size={12} />
    </button>
  );

  let body;
  if (recording) {
    body = (
      <div className="acpmux-capture__row" key="recording" data-row="recording">
        <span className="acpmux-capture__dot" aria-hidden="true" />
        <span className="acpmux-capture__elapsed" role="timer">
          {phase.kind === "finishing" ? t("capture.finishing") : elapsed}
        </span>
        <span className="acpmux-capture__what">{t("capture.recordingApp")}</span>
        <button
          type="button"
          className="acpmux-capture__stop"
          disabled={phase.kind === "finishing"}
          onClick={actions.stop}
        >
          <Icon name="action.stop" size={12} />
          {t("capture.stop")}
        </button>
      </div>
    );
  } else if (look === "segmented") {
    body = (
      <div className="acpmux-capture__column" key="segmented">
        <div className="acpmux-capture__row">
          <fieldset className="acpmux-capture__modes" aria-label={t("capture.title")}>
            {(["shot", "record"] as const).map((each) => (
              <button
                key={each}
                type="button"
                aria-pressed={mode === each}
                className="acpmux-capture__mode"
                onClick={() => setMode(each)}
              >
                {t(each === "shot" ? "capture.screenshot" : "capture.record")}
              </button>
            ))}
          </fieldset>
          {close}
        </div>
        <div className="acpmux-capture__row" data-wrap="">
          {mode === "shot" ? CAPTURE_TARGETS.map(targetButton) : options}
          <span className="acpmux-capture__spacer" />
          {destinations}
          <button
            type="button"
            className="acpmux-capture__go"
            disabled={waiting}
            onClick={() => (mode === "shot" ? actions.shoot(target) : actions.record())}
          >
            {t("capture.go")}
          </button>
        </div>
      </div>
    );
  } else if (look === "chip") {
    body = (
      <div className="acpmux-capture__row" key="chip">
        {CAPTURE_TARGETS.map(targetButton)}
        <span className="acpmux-capture__divider" aria-hidden="true" />
        {recordButton}
        {close}
      </div>
    );
  } else {
    body = (
      <div className="acpmux-capture__row" key="band" data-wrap="">
        <fieldset className="acpmux-capture__group" aria-label={t("capture.screenshot")}>
          {CAPTURE_TARGETS.map(targetButton)}
        </fieldset>
        <span className="acpmux-capture__divider" aria-hidden="true" />
        <span className="acpmux-capture__group">
          {recordButton}
          {options}
        </span>
        <span className="acpmux-capture__spacer" />
        {destinations}
        {close}
      </div>
    );
  }

  const settle = (event: React.SyntheticEvent) => {
    if (leaving && event.target === event.currentTarget) done();
  };
  return (
    <div
      ref={outer}
      className="acpmux-capture"
      data-look={look}
      data-open={open || undefined}
      data-settled={settled || undefined}
      style={{ "--acpmux-capture-height": `${open && arrived ? height : 0}px` } as CSSProperties}
      data-leaving={leaving || undefined}
      onTransitionEnd={settle}
      onTransitionCancel={settle}
    >
      {(open || leaving) && (
        <div ref={inner} className="acpmux-capture__room" aria-hidden={leaving || undefined}>
          <section className="acpmux-capture__body" aria-label={t("capture.title")}>
            {body}
          </section>
        </div>
      )}
    </div>
  );
}
