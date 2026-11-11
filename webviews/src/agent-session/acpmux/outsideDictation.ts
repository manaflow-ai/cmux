// Dictation in another app, seen from the composer (design/composer-dictation.md): while some other
// app holds the microphone (ChatGPT's dictation, Wispr Flow, a call) and a composer has the
// keyboard, the mic shows a small drawn wave in its own place (DictationButton), and its tooltip
// names the app. The host reads whether input runs and which app runs it (CoreAudio, Swift
// MicrophoneActivity). When cmux already has microphone permission, the host also opens a meter-only
// input tap (`metered: true`) and sends the input level as `micLevel` about 12 times a second, so
// the wave follows the real level; it keeps no audio. Without permission it never asks, and the
// wave stays drawn.
// Leo, 2026-11-07: "some sort of indicator that it's like, oh yeah, hey, we recognize that you're
// using your microphone right now ... But of course ... the benefit of having nothing there is just
// that, okay, you can still use the composer normally while you are dictating your other thing."
// So it never takes focus, never blocks a key and never moves or resizes anything.
//
// The page asks the host to watch (`dictation.watchMicrophone {on}`) only while one of its
// composers has the keyboard and the window has focus; the host's listeners stop with the last
// watcher, so nothing runs while no composer is focused. The host's answers come as the
// `micActivity` and `micLevel` events (pageHost.ts).
import { useEffect, useState, useSyncExternalStore, type RefObject } from "react";
import { callHost } from "./composer/attachmentSources";

/// `metered`: the host measures the input level (`micLevel`); absent, the wave is drawn.
export type OutsideDictation = { active: boolean; bundleId?: string; name?: string; metered?: boolean };

const IDLE: OutsideDictation = { active: false };
let current: OutsideDictation = IDLE;
const listeners = new Set<() => void>();

/// The host's `micActivity` value (and the gallery's stand-in).
export function setOutsideDictation(value: unknown): void {
  const raw = (value && typeof value === "object" ? value : {}) as Record<string, unknown>;
  const next: OutsideDictation =
    raw.active === true
      ? {
          active: true,
          bundleId: typeof raw.bundleId === "string" ? raw.bundleId : undefined,
          name: typeof raw.name === "string" && raw.name ? raw.name : undefined,
          metered: raw.metered === true || undefined,
        }
      : IDLE;
  if (!next.metered) clearOutsideLevel();
  if (
    next.active === current.active &&
    next.bundleId === current.bundleId &&
    next.name === current.name &&
    next.metered === current.metered
  )
    return;
  current = next;
  for (const listener of listeners) listener();
}

/// The last few outside input levels, oldest first, apart from cmux's own (dictation.ts): only the
/// mark's bars read them (OutsideLevelBars), so a level re-renders the bars, not the composer.
export const OUTSIDE_BARS = 4;
const quiet: readonly number[] = Array(OUTSIDE_BARS).fill(0);
const level = { samples: quiet, listeners: new Set<() => void>() };
function clearOutsideLevel(): void {
  if (level.samples === quiet) return;
  level.samples = quiet;
  for (const listener of level.listeners) listener();
}
/// The host's `micLevel` value, `{level}` in 0...1; kept only while the host meters.
export function setOutsideLevel(value: unknown): void {
  const raw = value && typeof value === "object" ? (value as Record<string, unknown>).level : undefined;
  if (!current.active || !current.metered || typeof raw !== "number" || !Number.isFinite(raw)) return;
  level.samples = [...level.samples.slice(1), Math.min(1, Math.max(0, raw))];
  for (const listener of level.listeners) listener();
}
export const subscribeOutsideLevel = (listener: () => void) => {
  level.listeners.add(listener);
  return () => {
    level.listeners.delete(listener);
  };
};
export const readOutsideLevel = () => level.samples;

const subscribe = (listener: () => void) => {
  listeners.add(listener);
  return () => {
    listeners.delete(listener);
  };
};
const read = () => current;

/// The composers that have the keyboard now; the host watches while there is one.
const watching = new Set<object>();
function setWatching(owner: object, on: boolean): void {
  const before = watching.size > 0;
  if (on) watching.add(owner);
  else watching.delete(owner);
  const after = watching.size > 0;
  if (before === after) return;
  if (!after) setOutsideDictation(IDLE);
  void callHost("dictation.watchMicrophone", { on: after }).catch(() => undefined);
}

/// Whether the composer around `anchor` (its form, or New Tab's composer) has the keyboard in a focused window.
function useComposerHasKeyboard(anchor: RefObject<Element | null>): boolean {
  const [has, setHas] = useState(false);
  useEffect(() => {
    const doc = anchor.current?.ownerDocument;
    if (!doc) return;
    const check = () => {
      // The chat composer is a form; New Tab's is `.nt-composer`, with no form around it.
      const box = anchor.current?.closest("form, .nt-composer") ?? anchor.current?.parentElement;
      const active = doc.activeElement;
      setHas(!!box && !!active && active !== doc.body && box.contains(active) && doc.hasFocus());
    };
    check();
    const win = doc.defaultView;
    doc.addEventListener("focusin", check);
    doc.addEventListener("focusout", check);
    win?.addEventListener("focus", check);
    win?.addEventListener("blur", check);
    return () => {
      doc.removeEventListener("focusin", check);
      doc.removeEventListener("focusout", check);
      win?.removeEventListener("focus", check);
      win?.removeEventListener("blur", check);
    };
  }, [anchor]);
  return has;
}

/// Another app's dictation as the composer around `anchor` should show it: idle unless that
/// composer has the keyboard (and only then does the host watch, for this page).
export function useOutsideDictation(anchor: RefObject<Element | null>): OutsideDictation {
  const focused = useComposerHasKeyboard(anchor);
  useEffect(() => {
    if (!focused) return;
    const owner = {};
    setWatching(owner, true);
    return () => setWatching(owner, false);
  }, [focused]);
  const value = useSyncExternalStore(subscribe, read, read);
  return focused ? value : IDLE;
}
