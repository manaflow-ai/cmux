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
//   watchArm(kind)   / watchResult(): every layout shift (no recent input) of one other turn transition, from now to
//                    watchResult(): "mid-turn" (Enter while a turn runs: a steer, or the queued prompt and its
//                    dequeue) and "compaction" (/compact: its running note, its end). { kind, shifts, shiftScore,
//                    shiftWhat, ms }. A send's own shifts are result()'s; snappy-bench adds them up as one counter,
//                    shifts per transition (shadow-leo for Leo, 2026-11-25: "count layout shifts across every turn
//                    transition (send, steer, compaction) in one counter").
//   seen(text)       whether a transcript row holds `text`; compacted(): whether a compaction note ended since watchArm
(() => {
  if (window.__snappyProbe) return true;
  const ROW = ".acpmux-row";
  const REPLY = ".acpmux-row.acpmux-assistant";
  let run = null;
  // The row ids of the compaction notes drawn as ended (any state but running).
  const endedNotes = () =>
    [...document.querySelectorAll(".cv-compaction")]
      .filter((note) => note.getAttribute("data-state") !== "running")
      .map((note) => note.closest("[data-row-id]")?.getAttribute("data-row-id") ?? "");
  let switching = null;
  let watch = null;
  const shiftsOf = (list) => ({
    shifts: list.length,
    shiftScore: Math.round(list.reduce((s, e) => s + e.value, 0) * 10000) / 10000,
    shiftWhat: [...new Set(list.map((s) => s.what))].slice(0, 3),
  });
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
        ...shiftsOf(run.shifts),
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
    watchArm(kind) {
      if (watch?.stop) watch.stop();
      const shifts = [];
      watch = { kind, shifts, start: performance.now(), endedBefore: new Set(endedNotes()) };
      watch.stop = shiftObserver((entry) => {
        if (entry.hadRecentInput || !(entry.value > 0)) return;
        shifts.push({ value: entry.value, what: describe(entry.sources?.[0]?.node), at: entry.startTime });
      });
      return true;
    },
    watchResult() {
      if (!watch) return { error: "not armed" };
      watch.stop();
      const w = watch;
      watch = null;
      return { kind: w.kind, ...shiftsOf(w.shifts), ms: r1(performance.now() - w.start) };
    },
    seen(text) {
      return [...document.querySelectorAll(ROW)].some((row) => row.textContent.includes(text));
    },
    // A note that ended since the last watchArm: an earlier /compact's note, still on screen, is not this one's end.
    compacted() {
      return endedNotes().some((id) => !watch?.endedBefore?.has(id));
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
