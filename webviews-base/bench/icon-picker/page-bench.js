// Runs inside the built icon picker page (WKWebView, wk-bench.swift injects it with
// callAsyncJavaScript after defining CATALOG, the system SF Symbol catalog in the session's shape,
// and MAX_EMOJI). Measures, with the real React build, the system emoji font and real symbol
// images from the harness's scheme handler:
//   openWithCatalog: the first session (catalog configure + reset + commit) -> forced layout
//   open:      a later session (store reset + synchronous React commit) -> forced layout -> 2nd rAF
//   keystroke: input event -> React commit -> forced style and layout, every prefix of typed
//              queries; `keystrokeFirst` is the first pass (cold glyph caches), `keystroke` a repeat
//   scroll:    one scroll step (scroll event -> window change -> React commit -> forced layout)
//              plus the rAF frame intervals while a 120 Hz scroll runs, for the emoji grid and for
//              the Symbols grid (system categories) in each rendering mode; fps = 1000 / p50
//              interval, `dropped` = intervals over 1.5 frames (25 ms at 60 Hz)
//   jump:      a category jump (store jump + scroll to the header) -> next rAF, every category
// Returns JSON; the harness prints it.
const picker = globalThis.cmuxIconPicker;
const input = () => document.querySelector(".icon-picker-search");
const grid = () => document.querySelector(".icon-grid-scroll");
const nextFrame = () => new Promise((resolve) => requestAnimationFrame(() => resolve(performance.now())));
const microtasks = async () => {
  for (let i = 0; i < 4; i++) await Promise.resolve();
};
const stats = (values) => {
  const sorted = [...values].sort((a, b) => a - b);
  const at = (q) => sorted[Math.min(sorted.length - 1, Math.floor(q * sorted.length))];
  return { n: sorted.length, p50: +at(0.5).toFixed(3), p95: +at(0.95).toFixed(3), max: +sorted.at(-1).toFixed(3) };
};
const setValue = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value").set;

async function typeText(text) {
  const times = [];
  for (let i = 1; i <= text.length; i++) {
    const t0 = performance.now();
    setValue.call(input(), text.slice(0, i));
    input().dispatchEvent(new Event("input", { bubbles: true }));
    await microtasks(); // React flushes a sync external-store update in a microtask
    grid()?.getBoundingClientRect();
    void document.body.offsetHeight;
    times.push(performance.now() - t0);
  }
  return times;
}

const result = { cells: 0 };
// open: average over sessions on the warm page
const opens = [];
const paints = [];
for (let i = 0; i < 20; i++) {
  await nextFrame();
  const t0 = performance.now();
  // The host sends the catalog once, on the first session.
  picker.open(i === 0 ? { id: "bench-0", ...CATALOG, maxEmojiVersion: MAX_EMOJI } : { id: `bench-${i}` });
  void document.body.offsetHeight;
  if (i === 0) result.openWithCatalog = +(performance.now() - t0).toFixed(3);
  else opens.push(performance.now() - t0);
  paints.push((await nextFrame()) - t0);
  await nextFrame();
}
result.open = stats(opens);
result.openToFirstFrame = stats(paints);
result.cells = document.querySelectorAll(".icon-cell").length;

// keystrokes: English and Japanese queries, every prefix, typed after clearing
const queries = [
  "thumbs up",
  "rocket",
  "face with tears of joy",
  "japan flag",
  "cat",
  "heart",
  "いいね",
  "ねこ",
  "ハート",
  "zzz",
];
for (const pass of ["keystrokeFirst", "keystroke"]) {
  let keys = [];
  for (const q of queries) {
    picker.open({ id: `q-${q}` });
    await nextFrame();
    keys = keys.concat(await typeText(q));
  }
  result[pass] = stats(keys);
}
// symbols tab
picker.open({ id: "sym", tab: "symbol" });
result.symbolKeystroke = stats(await typeText("person.crop.circle"));
picker.open({ id: "sym-kw", tab: "symbol" });
result.symbolKeywordKeystroke = stats(await typeText("favorite"));
result.symbolCount = CATALOG.symbols.length;
result.symbolCategories = (CATALOG.symbolCategories ?? []).length;

// scroll: synchronous work per step, 30 px steps (fast 120 Hz flick) over the whole emoji grid
picker.open({ id: "scroll" });
const el = grid();
const steps = [];
for (let top = 0; top < el.scrollHeight - el.clientHeight; top += 30) {
  const t0 = performance.now();
  el.scrollTop = top;
  el.dispatchEvent(new Event("scroll"));
  await microtasks();
  void el.offsetHeight;
  steps.push(performance.now() - t0);
}
result.scrollStep = stats(steps);
result.scrollHeight = el.scrollHeight;
// scroll: frame intervals with one 30 px step per rAF
async function scrollFrames(el) {
  el.scrollTop = 0;
  const frames = [];
  let last = await nextFrame();
  for (let top = 0; top < el.scrollHeight - el.clientHeight; top += 30) {
    el.scrollTop = top;
    const now = await nextFrame();
    frames.push(now - last);
    last = now;
  }
  const interval = stats(frames);
  return { ...interval, fps: +(1000 / interval.p50).toFixed(1), dropped: frames.filter((ms) => ms > 25).length };
}
result.scrollFrameInterval = await scrollFrames(el);
result.mountedAfterScroll = document.querySelectorAll(".icon-cell").length;

// Symbols grid (system categories), in each rendering mode: images load as cells mount.
result.symbolScroll = {};
for (const mode of ["monochrome", "hierarchical", "multicolor"]) {
  picker.store.setSymbolMode(mode);
  picker.open({ id: `sym-scroll-${mode}`, tab: "symbol", symbolStyle: `bench-${mode}` });
  await nextFrame();
  const symbolGrid = grid();
  result.symbolScroll[mode] = { height: symbolGrid.scrollHeight, ...(await scrollFrames(symbolGrid)) };
}
picker.store.setSymbolMode("monochrome");

// Section jumps (Alt-Down): every section on both grids -> next frame.
const jumpTimes = [];
for (const tab of ["emoji", "symbol"]) {
  picker.open({ id: `jump-${tab}`, tab });
  await nextFrame();
  for (const target of picker.store.getSnapshot().layout.sections) {
    const t0 = performance.now();
    const top = picker.store.jump(target.id);
    const scroller = grid();
    scroller.scrollTop = top ?? 0;
    scroller.dispatchEvent(new Event("scroll"));
    jumpTimes.push((await nextFrame()) - t0);
  }
}
result.jump = stats(jumpTimes);
return JSON.stringify(result);
