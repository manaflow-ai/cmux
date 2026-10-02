// Paint tracking for async renderers (Pierre code cards, a screen's own panes).
//
// window.__atlasReady is the promise scripts/compare.mjs awaits before its screenshot.
// Each async renderer registers a pending render and settles it once it has painted;
// the promise resolves two frames after the last pending render settles, provided no new
// render registered in between (React StrictMode detaches and re-attaches refs inside one
// commit, so a count that touches zero for a moment must not resolve the screen).
// Screens without async renderers never arm it; compare.mjs awaits `undefined`.

type W = Window & { __atlasReady?: Promise<unknown> };

let pending = 0;
let resolveReady: (() => void) | null = null;

function arm() {
  if (resolveReady) return;
  const mine = new Promise<void>((r) => (resolveReady = r));
  // Keep any readiness promise a screen set up itself (e.g. at module scope).
  const prev = (window as W).__atlasReady;
  (window as W).__atlasReady = prev ? Promise.all([prev, mine]) : mine;
}

function settleWhenIdle() {
  requestAnimationFrame(() =>
    requestAnimationFrame(() => {
      if (pending !== 0 || !resolveReady) return;
      const r = resolveReady;
      resolveReady = null;
      r();
    }),
  );
}

/** Register one pending async render. Call the result once it has painted (idempotent). */
export function trackRender(): () => void {
  arm();
  pending++;
  let done = false;
  return () => {
    if (done) return;
    done = true;
    pending--;
    if (pending === 0) settleWhenIdle();
  };
}
