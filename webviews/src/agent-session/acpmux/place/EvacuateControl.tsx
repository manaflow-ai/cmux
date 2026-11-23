import { EnvironmentIcon } from "../EnvironmentPicker";
import { useT, type Translate } from "../i18n";
import { useNow } from "./MoveProgress";
import {
  MOVE_STEPS,
  evacuateCounts,
  evacuateElapsed,
  evacuateIdle,
  evacuateRunning,
  evacuateSegments,
  failedSessions,
  seconds,
  stepKey,
  type EvacuateChat,
  type EvacuateState,
} from "./placeModel";
import "./place.css";

/// How Evacuate draws while chats move (EvacuateControl.gallery.tsx compares them): `bar`, one summary
/// line with a segmented bar of the chats; `panel`, one row per chat with its step or state; `chip`,
/// a compact pill for the header.
export type EvacuateLook = "bar" | "panel" | "chip";

/// Which part to draw: the `head` (the button, or the chip) goes in the chat list's header, the
/// `body` (the bar or the panel) under it; `all` is both, stacked (the gallery's view).
export type EvacuatePart = "head" | "body" | "all";

/// What ships (EvacuateControl.gallery.tsx compares the others).
export const SHIPPED_EVACUATE: EvacuateLook = "panel";

function summaryText(state: EvacuateState, t: Translate): string {
  const counts = evacuateCounts(state);
  if (counts.running > 0) return t("place.evacuate.running", { running: counts.running, total: counts.total });
  return counts.failed > 0
    ? t("place.evacuate.finishedFailed", { done: counts.done, total: counts.total, failed: counts.failed })
    : t("place.evacuate.finished", { done: counts.done, total: counts.total });
}

function chatStatus(chat: EvacuateChat, t: Translate): string {
  if (chat.state === "moving" && chat.step) {
    const index = MOVE_STEPS.indexOf(chat.step);
    return `${t(stepKey(chat.step, "toCloud"))} ${t("place.evacuate.stepShort", { i: index + 1, n: MOVE_STEPS.length })}`;
  }
  return t(`place.evacuate.state.${chat.state === "moving" ? "queued" : chat.state}`);
}

/// Evacuate to Cloud: a visible button that moves every chat on this Mac, each to its own Cloud VM,
/// and the progress of that, for several chats at once: the clock, Cancel, and Retry for the ones that
/// failed. Drawing only: the app decides what moves and in what order, and writes `tabState.evacuate`.
export function EvacuateControl({
  state,
  look = SHIPPED_EVACUATE,
  part = "all",
  onEvacuate,
  onCancel,
  now: fixedNow,
}: {
  state?: EvacuateState;
  look?: EvacuateLook;
  part?: EvacuatePart;
  /// All chats on this Mac (no argument), or just the failed ones (Retry).
  onEvacuate(sessions?: readonly string[]): void;
  onCancel(): void;
  /// Gallery and tests: the clock, so a fixture reads the same on every run.
  now?: number;
}) {
  const t = useT();
  const running = evacuateRunning(state);
  const clock = useNow(running, fixedNow);
  const idle = evacuateIdle(state);
  const head = part !== "body";
  const body = part !== "head";
  const failed = state ? failedSessions(state) : [];
  const elapsed = state ? t("place.evacuate.elapsed", { elapsed: seconds(evacuateElapsed(state, clock)) }) : "";
  const cancel = running && (
    <button type="button" className="acpmux-move-btn" data-testid="evacuate-cancel" onClick={onCancel}>
      {t("place.move.cancel")}
    </button>
  );
  const retry = !running && failed.length > 0 && (
    <button
      type="button"
      className="acpmux-move-btn"
      data-primary="true"
      data-testid="evacuate-retry"
      onClick={() => onEvacuate(failed)}
    >
      {t("place.evacuate.retry")}
    </button>
  );
  const button = !running && (
    <button
      type="button"
      className="acpmux-evac-btn"
      data-testid="evacuate-button"
      title={t("place.evacuate.hint")}
      onClick={() => onEvacuate()}
    >
      <EnvironmentIcon kind="cloud" />
      {t("place.evacuate.button")}
    </button>
  );
  const chip =
    look === "chip" && state && !idle ? (
      <span className="acpmux-evac acpmux-evac-chip" data-look="chip" data-running={running ? "true" : undefined}>
        <span className="acpmux-move-dot" data-state={running ? "moving" : failed.length > 0 ? "failed" : "live"} />
        <span className="acpmux-evac-text">{summaryText(state, t)}</span>
        {running && <span className="acpmux-move-clock">{elapsed}</span>}
        {cancel}
        {retry}
      </span>
    ) : null;
  const shown = state && !idle && look !== "chip" ? state : undefined;
  const counts = shown ? evacuateCounts(shown) : undefined;
  const summary = shown && (
    <div className="acpmux-evac-line">
      <span className="acpmux-evac-title">{summaryText(shown, t)}</span>
      {running && <span className="acpmux-move-clock">{elapsed}</span>}
      {cancel}
      {retry}
    </div>
  );
  const progress = shown && counts && (
    <section
      className="acpmux-evac"
      data-look={look}
      data-running={running ? "true" : undefined}
      aria-label={t("place.evacuate.label")}
    >
      {summary}
      {look === "bar" && (
        <div
          className="acpmux-move-bar"
          role="progressbar"
          aria-label={t("place.evacuate.label")}
          aria-valuemin={0}
          aria-valuemax={counts.total}
          aria-valuenow={counts.done}
          aria-valuetext={summaryText(shown, t)}
        >
          {evacuateSegments(shown).map((segment, index) => (
            <span key={index} data-state={segment} />
          ))}
        </div>
      )}
      {look === "panel" && shown.chats && (
        <ul className="acpmux-evac-rows" aria-label={t("place.evacuate.chats")}>
          {shown.chats.map((chat, index) => (
            <li key={chat.session || index} data-state={chat.state}>
              <span className="acpmux-move-dot" data-state={dotState(chat)} aria-hidden="true" />
              <span className="acpmux-evac-chat">{chat.title}</span>
              <span className="acpmux-evac-status">{chatStatus(chat, t)}</span>
              {chat.reason && chat.state === "failed" && <span className="acpmux-evac-reason">{chat.reason}</span>}
            </li>
          ))}
        </ul>
      )}
    </section>
  );
  return (
    <>
      {head && chip}
      {head && button}
      {body && progress}
    </>
  );
}

const dotState = (chat: EvacuateChat) =>
  chat.state === "live" ? "live" : chat.state === "failed" || chat.state === "cancelled" ? "failed" : "moving";
