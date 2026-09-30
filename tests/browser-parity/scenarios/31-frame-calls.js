// Many frame calls in flight: a page of 300 iframes (401 frames, a third
// cross-origin, a third nested) snapshots in bounded time, and 400
// concurrent calls into the main frame or into every frame all finish. The
// app's driver used to read the whole frame tree for every call, so a burst
// of calls took minutes. The limits are generous; the target is under 1 s.
// oracle: skip (driver timing and snapshot text)
// ---- cell cmux-only
await page.setViewportSize({ width: 1280, height: 800 });
await page.goto(`${PRIMARY}/stress/stress.html?kind=iframes&n=300&peer=${encodeURIComponent(PEER)}`);
await page.waitForLoadState("load");
await snapshot();
let t = Date.now();
const s = await snapshot();
const snapshotMs = Date.now() - t;
emitCmux("frame-buttons", (s.tree.match(/button "(Frame|Inner) /g) || []).length);
emitCmux("snapshot-under-3s", snapshotMs < 3000 || `took ${snapshotMs}ms`);
const main = page.mainFrame();
t = Date.now();
const mainResults = await Promise.all(Array.from({ length: 400 }, (_, i) => main.evaluate((n) => n + 1, i)));
const mainMs = Date.now() - t;
emitCmux("main-calls", mainResults.every((v, i) => v === i + 1));
emitCmux("main-calls-under-3s", mainMs < 3000 || `took ${mainMs}ms`);
const frames = page.frames().slice(1);
t = Date.now();
const frameResults = await Promise.all(frames.map((f) => f.evaluate(() => document.querySelector("button") ? 1 : 0)));
const framesMs = Date.now() - t;
emitCmux("frame-calls", `${frameResults.length} frames, ${frameResults.filter((v) => v === 1).length} with a button`);
emitCmux("frame-calls-under-3s", framesMs < 3000 || `took ${framesMs}ms`);
