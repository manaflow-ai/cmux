// l10n-allow-file: benchmark output, not shipped UI.
// A runner's speed beside a timing row, so a slower runner reads as a slower runner and not as a slower page.
//
// The perf cron's Linux runners differ by close to 2x from one job to the next (blacksmith 4 vCPU, sometimes
// 2 vCPU): chat_open.god.compact.attach_to_latest read 89.1, 142.4 and 174.1 ms on three tips whose pane did the same
// work, while the same loads' DOMContentLoaded read 17.8, 30.6 and 31.6 ms (about 5.0, 4.65 and 5.5 times it).
// bench/hostLoad.ts can't see that: a slow core with a free neighbour spins at full speed for its 20 ms, so its
// contention factor is 1.
//
// So a bench loads a fixed calibration page (CALIBRATION_HTML: a fixed parse, script and layout workload that no
// change to the pane touches) in every round, interleaved with its real loads (roundOrder), and divides each round's
// time by that round's calibration (perCalibration). The quotient is the row's time in units of this runner's speed,
// which holds across runners where the raw ms does not; the raw ms row stays as it was beside it.

/// The arms of round `round` (pure): the arms rotated by the round, so over any `arms.length` rounds each arm takes
/// each place once and no arm always runs first or last. Two arms alternate (a, b then
/// b, a), as chat-open's ARMS did.
export function roundOrder<T>(arms: readonly T[], round: number): T[] {
  if (!arms.length) return [];
  const shift = ((round % arms.length) + arms.length) % arms.length;
  return [...arms.slice(shift), ...arms.slice(0, shift)];
}

/// The median (pure): the middle value of an odd count, the mean of the two middle values of an even one; NaN for none.
export function median(values: readonly number[]): number {
  const sorted = values.filter(Number.isFinite).sort((a, b) => a - b);
  if (!sorted.length) return Number.NaN;
  const mid = sorted.length >> 1;
  return sorted.length % 2 ? sorted[mid]! : (sorted[mid - 1]! + sorted[mid]!) / 2;
}

/// The median of each round's value divided by that same round's calibration (pure), to 4 decimals. Rounds pair by
/// index; a round without a positive calibration, or without a finite value, is left out. NaN when no round pairs.
/// Pairing by round, not dividing the two medians, keeps a runner that slows down mid-job from skewing the quotient.
export function perCalibration(values: readonly number[], calibrations: readonly number[]): number {
  const ratios: number[] = [];
  for (let i = 0; i < Math.min(values.length, calibrations.length); i += 1) {
    const value = values[i]!;
    const calibration = calibrations[i]!;
    if (Number.isFinite(value) && Number.isFinite(calibration) && calibration > 0) ratios.push(value / calibration);
  }
  const mid = median(ratios);
  return Number.isFinite(mid) ? Math.round(mid * 10_000) / 10_000 : Number.NaN;
}

/// Bump with any change to CALIBRATION_HTML: it is the calibration row's `version`, so the perf cron rebases the
/// calibration and every per-calibration row instead of calling the new page's speed a regression.
export const CALIBRATION_VERSION = 1;

/// The fixed calibration page: parse a 256 KiB JSON string (an attach page's parse), build 1,500 rows of nested
/// elements with text (a transcript's first render), lay them out and read every row's height (its layout passes),
/// then mark the time after the next paint in window.__calibrated (ms from navigation start). Never edit it without
/// bumping CALIBRATION_VERSION.
export const CALIBRATION_HTML = `<!doctype html>
<html><head><meta charset="utf-8"><title>calibration</title>
<style>body{margin:0;font:13px/1.45 system-ui,sans-serif}.row{display:flex;gap:8px;padding:6px 12px;border-bottom:1px solid #ddd}.row b{flex:none;width:80px}.row span{flex:1;overflow-wrap:anywhere}</style>
</head><body><main id="list"></main><script>
(() => {
  const words = "lorem ipsum dolor sit amet consectetur adipiscing elit sed do eiusmod tempor incididunt ut labore".split(" ");
  const items = [];
  for (let i = 0; i < 1500; i += 1) {
    let text = "";
    for (let w = 0; w < 24 + (i % 17); w += 1) text += words[(i * 7 + w * 3) % words.length] + " ";
    items.push({ id: "row-" + i, kind: i % 4 ? "assistant" : "user", text: text });
  }
  let json = JSON.stringify(items);
  while (json.length < 262144) json += " ";
  const parsed = JSON.parse(json);
  const list = document.getElementById("list");
  const fragment = document.createDocumentFragment();
  for (const item of parsed) {
    const row = document.createElement("div");
    row.className = "row";
    row.dataset.rowId = item.id;
    const who = document.createElement("b");
    who.textContent = item.kind;
    const body = document.createElement("span");
    body.textContent = item.text;
    row.append(who, body);
    fragment.append(row);
  }
  list.append(fragment);
  let height = 0;
  for (const row of list.children) height += row.getBoundingClientRect().height;
  window.__calibrationHeight = height;
  requestAnimationFrame(() => setTimeout(() => { window.__calibrated = performance.now(); }, 0));
})();
</script></body></html>`;
