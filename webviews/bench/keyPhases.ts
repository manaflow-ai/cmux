// l10n-allow-file: benchmark output, not shipped UI.
// With --phases (composer-typing.bench.ts): where each typed key's time goes before its frame, from the page's own
// event timestamps, no trace, so it reads WebKit (the engine the app ships), whose run goes through composer-load.ts. Per key:
//   listener   the key's event timeStamp to the first keydown capture listener (the queue ahead of the key)
//   keydown    the keydown listeners
//   kd_kp      the last keydown listener to keypress: the engine's own default-action work, style first
//   kp_bi      keypress to beforeinput
//   bi_in      beforeinput to input: the editor's DOM change
//   input      the input listeners
//   frame      the last input listener to the key's requestAnimationFrame
//   lay0       a forced layout at keydown (what was dirty before the key: near 0 means nothing was)
// It found the minifier's `:is(...)` around a `:has(:focus-visible)` list (scripts/postcss/splitHasLists.mjs): WebKit
// kd_kp 2.8 ms per key with it, 0.5 without, Chromium 0.5 either way. Printed as one `KEY-PHASES` JSON line per run:
//   bun bench/composer-typing.bench.ts --engine webkit --mode L0 --lengths 60 --keys 300 --gap 20 --phases
import type { Page } from "playwright";

export const KEY_PHASES = ["listener", "keydown", "kd_kp", "kp_bi", "bi_in", "input", "frame", "lay0"] as const;

export type PhaseStats = { n: number; mean: number; p50: number | null; p95: number | null };

/// Runs in the page before its own code, so its capture listeners are the first a key reaches.
export function keyPhasesProbe() {
  const names = ["listener", "keydown", "kd_kp", "kp_bi", "bi_in", "input", "frame", "lay0"];
  const ph: Record<string, number[]> = Object.fromEntries(names.map((name) => [name, []]));
  type Key = { ts: number; kd0: number; kd1?: number; kp0?: number; bi0?: number; in0?: number; in1?: number };
  let key: Key | undefined;
  const now = () => performance.now();
  const on = (type: string, fn: (event: Event) => void, capture: boolean) =>
    EventTarget.prototype.addEventListener.call(document, type, fn, capture);
  on(
    "keydown",
    (event) => {
      const a = now();
      void document.body.offsetHeight;
      ph.lay0!.push(now() - a);
      key = { ts: event.timeStamp, kd0: a };
    },
    true,
  );
  on("keydown", () => key && (key.kd1 = now()), false);
  on("keypress", () => key && (key.kp0 = now()), true);
  on("beforeinput", () => key && (key.bi0 = now()), true);
  on("input", () => key && (key.in0 = now()), true);
  on(
    "input",
    () => {
      const k = key;
      key = undefined;
      if (!k || k.bi0 === undefined || k.in0 === undefined) return;
      k.in1 = now();
      requestAnimationFrame(() => {
        const kd1 = k.kd1 ?? k.kd0;
        ph.listener!.push(k.kd0 - k.ts);
        ph.keydown!.push(kd1 - k.kd0);
        if (k.kp0 !== undefined) {
          ph.kd_kp!.push(k.kp0 - kd1);
          ph.kp_bi!.push(k.bi0! - k.kp0);
        }
        ph.bi_in!.push(k.in0! - k.bi0!);
        ph.input!.push(k.in1! - k.in0!);
        ph.frame!.push(now() - k.in1!);
      });
    },
    false,
  );
  const q = (a: number[], p: number) => {
    const s = [...a].sort((x, y) => x - y);
    return s.length ? Math.round(s[Math.min(s.length - 1, Math.floor(p * s.length))]! * 100) / 100 : null;
  };
  (window as any).__keyPhases = () =>
    Object.fromEntries(
      Object.entries(ph).map(([name, a]) => [
        name,
        {
          n: a.length,
          mean: Math.round((a.reduce((x, y) => x + y, 0) / Math.max(1, a.length)) * 100) / 100,
          p50: q(a, 0.5),
          p95: q(a, 0.95),
        },
      ]),
    );
}

export async function readKeyPhases(page: Page): Promise<Record<string, PhaseStats> | undefined> {
  return page.evaluate(() => (window as any).__keyPhases?.());
}
