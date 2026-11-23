// Host-ticking text: a Text with `date` (Unix ms) and `dateStyle` is formatted and ticked here, as
// SwiftUI's `Text(date, style:)` is, with no app call and no scene batch. Every ticking Text reads
// one shared clock, aligned to the wall-clock second and paused while the document is hidden, so
// a seconds hand or a countdown costs the app nothing against its refresh budget. The page's
// locale and time zone format it; a Text's `timeZone` (an IANA name) overrides the zone.
// The native twin is AppSceneDateText (Packages/macOS/CmuxNext/.../NativeRender).
import { useSyncExternalStore } from "react";
import { intl } from "../../ui/intl";

export type SceneDateStyle = "time" | "timer" | "relative" | "date" | "offset";
const STYLES = new Set<string>(["time", "timer", "relative", "date", "offset"]);

/** The Text's date style, or undefined when it is not a ticking Text (no finite `date`). */
export function sceneDateStyle(props: Readonly<Record<string, unknown>>): SceneDateStyle | undefined {
  if (typeof props.date !== "number" || !Number.isFinite(props.date)) return undefined;
  return typeof props.dateStyle === "string" && STYLES.has(props.dateStyle)
    ? (props.dateStyle as SceneDateStyle)
    : "time";
}

/** The zone a Text asks for, when the engine knows it; else the page's. */
function zone(timeZone: unknown): string | undefined {
  if (typeof timeZone !== "string" || !timeZone) return undefined;
  try {
    intl.DateTimeFormat(undefined, { timeZone });
    return timeZone;
  } catch {
    return undefined;
  }
}

const SECOND = 1000;
const UNITS: Array<[Intl.RelativeTimeFormatUnit, number]> = [
  ["day", 86_400],
  ["hour", 3_600],
  ["minute", 60],
  ["second", 1],
];

function unit(value: number, name: string, display: "short" | "long", locale?: string, sign = false): string {
  return intl
    .NumberFormat(locale, {
      style: "unit",
      unit: name,
      unitDisplay: display,
      signDisplay: sign ? "always" : "auto",
    })
    .format(value);
}

/**
 * `date` as `style` shows it at `now` (both Unix ms):
 * - `time`: the clock time, "9:41 AM" (the locale's hour cycle).
 * - `date`: the long date, "November 16, 2026".
 * - `timer`: the time to or since the date as a timer, "4:05" or "1:02:03".
 * - `relative`: the time to or since the date in its two largest units, "2 hr, 23 min".
 * - `offset`: the signed difference in its largest unit, "+2 hours", "-3 minutes".
 * `options.locale` and `options.timeZone` default to the page's.
 */
export function formatSceneDate(
  style: SceneDateStyle,
  date: number,
  now: number,
  options: { locale?: string; timeZone?: unknown } = {},
): string {
  const { locale } = options;
  const timeZone = zone(options.timeZone);
  switch (style) {
    case "time":
      return intl.DateTimeFormat(locale, { hour: "numeric", minute: "2-digit", timeZone }).format(date);
    case "date":
      return intl.DateTimeFormat(locale, { dateStyle: "long", timeZone }).format(date);
    case "timer": {
      const total = Math.floor(Math.abs(date - now) / SECOND);
      const hours = Math.floor(total / 3_600);
      const minutes = Math.floor((total % 3_600) / 60);
      const seconds = String(total % 60).padStart(2, "0");
      return hours > 0 ? `${hours}:${String(minutes).padStart(2, "0")}:${seconds}` : `${minutes}:${seconds}`;
    }
    case "relative": {
      let left = Math.floor(Math.abs(date - now) / SECOND);
      const parts: string[] = [];
      for (const [name, size] of UNITS) {
        if (parts.length === 2) break;
        const count = Math.floor(left / size);
        if (count === 0 && (parts.length === 0 ? name !== "second" : true)) continue;
        parts.push(unit(count, name, "short", locale));
        left -= count * size;
      }
      return parts.join(", ");
    }
    case "offset": {
      const seconds = Math.trunc((date - now) / SECOND);
      const [name, size] = UNITS.find(([, size]) => Math.abs(seconds) >= size) ?? ["second", 1];
      return unit(Math.trunc(seconds / size), name, "long", locale, true);
    }
  }
}

// The shared clock: one timeout chain for every ticking Text on the page.
type Listener = () => void;
const listeners = new Set<Listener>();
let now = Date.now();
let timer: ReturnType<typeof setTimeout> | undefined;
let watchingVisibility = false;

const hidden = () => typeof document !== "undefined" && document.visibilityState === "hidden";

function schedule() {
  if (timer !== undefined) clearTimeout(timer);
  timer = undefined;
  if (!listeners.size || hidden()) return;
  // To the next wall-clock second, so every ticking Text turns over together with the system clock.
  timer = setTimeout(tick, SECOND - (Date.now() % SECOND));
}

function tick() {
  timer = undefined;
  now = Date.now();
  // A snapshot: a listener may subscribe or unsubscribe while the tick runs.
  for (const listener of Array.from(listeners)) listener();
  schedule();
}

function onVisibility() {
  // Back on screen: catch up at once, then tick again.
  if (!hidden()) tick();
  else schedule();
}

function subscribe(listener: Listener): () => void {
  listeners.add(listener);
  if (!watchingVisibility && typeof document !== "undefined") {
    document.addEventListener("visibilitychange", onVisibility);
    watchingVisibility = true;
  }
  if (listeners.size === 1) {
    now = Date.now();
    schedule();
  }
  return () => {
    listeners.delete(listener);
    if (listeners.size) return;
    if (timer !== undefined) clearTimeout(timer);
    timer = undefined;
    if (watchingVisibility && typeof document !== "undefined") {
      document.removeEventListener("visibilitychange", onVisibility);
      watchingVisibility = false;
    }
  };
}

const snapshot = () => now;
const idle = () => () => {};

/** The shared clock's last tick (Unix ms) while `active`; a Text without a date subscribes to nothing. */
export function useSceneNow(active: boolean): number {
  return useSyncExternalStore(active ? subscribe : idle, snapshot, snapshot);
}

/** Whether the shared clock is running (tests). */
export function sceneClockRunning(): boolean {
  return timer !== undefined;
}
