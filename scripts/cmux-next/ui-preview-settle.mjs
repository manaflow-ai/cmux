// The UI preview shooter's settle step (ui-preview-shoot.mjs): before a scene is shot, every finite animation on
// the page has ended, so the picture is the settled frame and not a point partway through an entrance fade. A fixed
// wait after the frame marks ready (300 ms, before 2026-11-28) shot the chat-motion-pass scene mid-fade: a warm
// gallery and a cold one drew it at two points of the fade, and the cached before of every transcript push differed
// from its after by the same 7.22% though neither side's code changed.
//
// settle runs in the page (page.evaluate(settle, opts)), so it names nothing outside its own body.
//   - Wait for each running finite animation (CSS animations, transitions and WAAPI alike) to finish, within
//     bound_ms; one still running at the bound is finished (Animation.finish()), so the shot is never mid-motion.
//   - Two frames after each pass, then look again: an animation a commit starts on the next frame is waited on too.
//   - An infinite one (a spinner) is paused at its start, so its phase is the same in every shot.
// It answers {passes, waited, finished, paused}: what it did, for the shooter's row.
export async function settle(opts = {}) {
  const boundMs = opts.bound_ms ?? 4000;
  const maxPasses = opts.max_passes ?? 8;
  const now = () => performance.now();
  const frame = () => new Promise((resolve) => requestAnimationFrame(() => resolve()));
  const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, Math.max(0, ms)));
  const endOf = (a) => {
    try {
      return a.effect?.getComputedTiming?.().endTime ?? Infinity;
    } catch {
      return Infinity;
    }
  };
  const live = (a) => a.playState === "running" || a.pending === true;
  const deadline = now() + boundMs;
  const out = { passes: 0, waited: 0, finished: 0, paused: 0 };
  for (;;) {
    await frame();
    await frame();
    const running = document.getAnimations().filter(live);
    const finite = running.filter((a) => Number.isFinite(endOf(a)));
    for (const a of running) {
      if (Number.isFinite(endOf(a))) continue;
      a.pause();
      a.currentTime = 0;
      out.paused += 1;
    }
    if (finite.length === 0) break;
    out.passes += 1;
    const left = deadline - now();
    if (left > 0 && out.passes <= maxPasses) {
      out.waited += finite.length;
      await Promise.race([Promise.all(finite.map((a) => a.finished.catch(() => {}))), sleep(left)]);
      continue;
    }
    for (const a of finite) {
      try {
        a.finish();
        out.finished += 1;
      } catch {
        // An animation removed while we looked: nothing to end.
      }
    }
    await frame();
    await frame();
    break;
  }
  return out;
}
