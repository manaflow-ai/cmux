// Runs inside the built icon picker page (WKWebView, wk-bench.swift injects it with
// callAsyncJavaScript). Measures, with the real React build and the system emoji font:
//   open:      session open (store reset + synchronous React commit) -> forced layout -> 2nd rAF
//   keystroke: input event -> React commit -> forced style and layout, every prefix of typed
//              queries; `keystrokeFirst` is the first pass (cold glyph caches), `keystroke` a repeat
//   scroll:    one scroll step (scroll event -> window change -> React commit -> forced layout)
//              plus the rAF frame intervals while a 120 Hz scroll runs
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
  picker.open(i === 0 ? { id: "bench-0", symbols: SYMBOLS, maxEmojiVersion: MAX_EMOJI } : { id: `bench-${i}` });
  void document.body.offsetHeight;
  opens.push(performance.now() - t0);
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
result.symbolCount = SYMBOLS.length;

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
el.scrollTop = 0;
const frames = [];
let last = await nextFrame();
for (let top = 0; top < el.scrollHeight - el.clientHeight; top += 30) {
  el.scrollTop = top;
  const now = await nextFrame();
  frames.push(now - last);
  last = now;
}
result.scrollFrameInterval = stats(frames);
result.mountedAfterScroll = document.querySelectorAll(".icon-cell").length;
return JSON.stringify(result);
