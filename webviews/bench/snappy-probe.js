// l10n-allow-file: bench probe, not shipped UI.
// The page half of snappy-bench (scripts/measure/snappy-bench.py; Leo 2026-11-25: "when you press enter, the stuff
// should just start playing. we dont need to wait/get blocked by anything on rendering."). One expression that
// installs `window.__snappyProbe` in an agent chat page (DevTools Runtime.evaluate), measuring only, changing nothing:
//   arm(marker)    from now: the Enter keydown (capture phase, its event.timeStamp), then every frame until result():
//                  the first frame whose DOM holds the sent row (a `.acpmux-row.acpmux-user` holding `marker`), the
//                  first frame that also holds a row after it (the assistant's reserved turn: thinking, working or the
//                  reply itself), the first frame with reply text after it (first token), and every layout shift
//   result()       stops and returns, all in ms from the keydown:
//     userPaintMs        keydown to the frame that paints the sent row (the rAF of that frame; elementPaintMs is the
//                        same row's element-timing paint where the engine reports one)
//     reservedPaintMs    keydown to the first frame painting a row after the sent one
//     sameFrame          the sent row and the reserved turn came in the same frame
//     firstTokenMs       keydown to the first frame with reply text after the sent row (null: none yet)
//     shifts, shiftScore layout-shift entries (no recent input) from the keydown to result(), and their sum
//     shiftWhat          the first three shifted nodes, tag and first class (no chat text)
//     reservedJumpPx     how far the reserved turn's bottom moved between its first frame and the first token's
//                        (a reserve that does not hold the reply's first line shifts what is under it)
//     rows               transcript rows at the keydown
//   switchArm()      / switchStatus() / switchResult(): from the page turning visible (visibilitychange) to the
//                    first frame with transcript rows: { visibleToPaintMs, rows }
(() => {
  if (window.__snappyProbe) return true;
  const ROW = ".acpmux-row";
  const REPLY = ".acpmux-row.acpmux-assistant";
  let run = null;
  let switching = null;
  const describe = (node) => {
    if (!node || !node.tagName) return "";
    const first = node.classList && node.classList.item(0);
    return `${node.tagName.toLowerCase()}${first ? `.${first}` : ""}`;
  };
  const shiftObserver = (onEntry) => {
    if (!PerformanceObserver.supportedEntryTypes?.includes("layout-shift")) return () => {};
    const observer = new PerformanceObserver((list) => list.getEntries().forEach(onEntry));
    observer.observe({ type: "layout-shift", buffered: false });
    return () => observer.disconnect();
  };
  const sentRow = (marker) =>
    [...document.querySelectorAll(`${ROW}.acpmux-user`)].reverse().find((row) => row.textContent.includes(marker));
  const after = (row) => {
    const rows = [...document.querySelectorAll(ROW)];
    const at = rows.indexOf(row);
    return at < 0 ? [] : rows.slice(at + 1).filter((r) => !r.classList.contains("acpmux-user"));
  };
  const frame = (time) => {
    if (!run || run.done) return;
    run.frames += 1;
    if (run.keydown !== undefined) {
      const row = sentRow(run.marker);
      if (row) {
        if (run.user === undefined) {
          run.user = time;
          row.setAttribute("elementtiming", `snappy-${run.marker}`);
        }
        const later = after(row);
        if (later.length && run.reserved === undefined) {
          run.reserved = time;
          run.reservedBottom = later[0].getBoundingClientRect().bottom;
          run.reservedWhat = describe(later[0]) + (later[0].classList.item(1) ? `.${later[0].classList.item(1)}` : "");
        }
        if (run.token === undefined) {
          const reply = later.find((r) => r.matches(REPLY) && r.textContent.trim().length > 0);
          if (reply) {
            run.token = time;
            if (later[0]) run.tokenBottom = later[0].getBoundingClientRect().bottom;
          }
        }
      }
    }
    requestAnimationFrame(frame);
  };
  const onKey = (event) => {
    if (!run || run.keydown !== undefined || event.key !== "Enter" || event.shiftKey) return;
    run.keydown = event.timeStamp;
    run.rows = document.querySelectorAll(ROW).length;
  };
  window.addEventListener("keydown", onKey, true);
  let elementEntries = [];
  if (PerformanceObserver.supportedEntryTypes?.includes("element")) {
    new PerformanceObserver((list) => elementEntries.push(...list.getEntries())).observe({
      type: "element",
      buffered: true,
    });
  }
  const r1 = (v) => (v === undefined || v === null ? null : Math.round(v * 10) / 10);
  window.__snappyProbe = {
    arm(marker) {
      if (run?.stop) run.stop();
      run = { marker, frames: 0, shifts: [], done: false };
      run.stop = shiftObserver((entry) => {
        if (run.keydown === undefined || entry.hadRecentInput || !(entry.value > 0)) return;
        run.shifts.push({ value: entry.value, what: describe(entry.sources?.[0]?.node), at: entry.startTime });
      });
      requestAnimationFrame(frame);
      return true;
    },
    status() {
      if (!run) return null;
      return {
        keydown: run.keydown !== undefined,
        user: run.user !== undefined,
        reserved: run.reserved !== undefined,
        token: run.token !== undefined,
      };
    },
    result() {
      if (!run) return { error: "not armed" };
      run.done = true;
      run.stop();
      const k = run.keydown;
      if (k === undefined) return { error: "no Enter keydown seen", frames: run.frames };
      const element = elementEntries.find((e) => e.identifier === `snappy-${run.marker}`);
      const elementAt = element ? element.presentationTime || element.renderTime || element.paintTime : undefined;
      const out = {
        userPaintMs: r1(run.user !== undefined ? run.user - k : undefined),
        elementPaintMs: r1(elementAt ? elementAt - k : undefined),
        reservedPaintMs: r1(run.reserved !== undefined ? run.reserved - k : undefined),
        sameFrame: run.user !== undefined && run.reserved === run.user,
        reservedWhat: run.reservedWhat ?? null,
        firstTokenMs: r1(run.token !== undefined ? run.token - k : undefined),
        shifts: run.shifts.length,
        shiftScore: Math.round(run.shifts.reduce((s, e) => s + e.value, 0) * 10000) / 10000,
        shiftWhat: [...new Set(run.shifts.map((s) => s.what))].slice(0, 3),
        reservedJumpPx: r1(
          run.tokenBottom !== undefined && run.reservedBottom !== undefined
            ? Math.abs(run.tokenBottom - run.reservedBottom)
            : undefined,
        ),
        rows: run.rows,
        frames: run.frames,
      };
      elementEntries = elementEntries.filter((e) => e !== element);
      return out;
    },
    switchArm() {
      switching = { armed: true };
      const seen = () => {
        if (document.visibilityState !== "visible" || !switching || switching.visible !== undefined) return;
        switching.visible = performance.now();
        const tick = (time) => {
          if (document.querySelectorAll(ROW).length) {
            switching.painted = time;
            switching.rows = document.querySelectorAll(ROW).length;
          } else requestAnimationFrame(tick);
        };
        requestAnimationFrame(tick);
      };
      document.addEventListener("visibilitychange", seen, { once: false });
      switching.off = () => document.removeEventListener("visibilitychange", seen);
      return true;
    },
    switchStatus() {
      return { visible: switching?.visible !== undefined, painted: switching?.painted !== undefined };
    },
    switchResult() {
      if (!switching) return { error: "not armed" };
      switching.off();
      const s = switching;
      switching = null;
      if (s.visible === undefined) return { error: "the page did not turn visible" };
      return { visibleToPaintMs: r1(s.painted !== undefined ? s.painted - s.visible : undefined), rows: s.rows ?? 0 };
    },
  };
  return true;
})();
