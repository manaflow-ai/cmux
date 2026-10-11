// Many frame calls in flight: a page of 300 iframes (401 frames, a third
// cross-origin, a third nested) snapshots about ten times slower than a page
// of 30 iframes, not a hundred, and 400 concurrent calls into the main frame
// or into every frame cost about ten times 40. The app's driver used to read
// the whole frame tree for every call, so time grew with the square of the
// frame count and a burst of 400 calls did not finish. The guards compare
// the runtime with itself so a loaded machine does not fail them; the
// absolute limits only catch a hang.
// oracle: skip (driver timing and snapshot text)
// ---- cell cmux-only
await page.setViewportSize({ width: 1280, height: 800 });
const iframes = (n) => `${PRIMARY}/stress/stress.html?kind=iframes&n=${n}&peer=${encodeURIComponent(PEER)}`;
const timed = async (fn) => {
  const t = Date.now();
  const value = await fn();
  return [value, Math.max(1, Date.now() - t)];
};
const snapshotMs = async (n) => {
  await page.goto(iframes(n));
  await page.waitForLoadState("load");
  await snapshot();
  const [s, ms] = await timed(() => snapshot());
  return [s, ms];
};
const [, smallMs] = await snapshotMs(30);
const [s, bigMs] = await snapshotMs(300);
emitCmux("frame-buttons", (s.tree.match(/button "(Frame|Inner) /g) || []).length);
// Ten times the frames; 30 is generous for linear, quadratic was over 30.
emitCmux("snapshot-scales-linearly", (bigMs < 30 * Math.max(smallMs, 50) && bigMs < 20000) || `30 iframes ${smallMs}ms, 300 iframes ${bigMs}ms`);
const main = page.mainFrame();
const burst = (n) => timed(() => Promise.all(Array.from({ length: n }, (_, i) => main.evaluate((k) => k + 1, i))));
const [, fewMs] = await burst(40);
const [results, manyMs] = await burst(400);
emitCmux("main-calls", results.every((v, i) => v === i + 1));
emitCmux("main-calls-scale-linearly", (manyMs < 30 * Math.max(fewMs, 50) && manyMs < 20000) || `40 calls ${fewMs}ms, 400 calls ${manyMs}ms`);
const frames = page.frames().slice(1);
const [frameResults, framesMs] = await timed(() => Promise.all(frames.map((f) => f.evaluate(() => (document.querySelector("button") ? 1 : 0)))));
emitCmux("frame-calls", `${frameResults.length} frames, ${frameResults.filter((v) => v === 1).length} with a button`);
emitCmux("frame-calls-finish", framesMs < 20000 || `took ${framesMs}ms`);
