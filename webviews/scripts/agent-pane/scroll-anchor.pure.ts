// Small dependency-free checks; run: bun scripts/agent-pane/scroll-anchor.pure.ts
import assert from "node:assert/strict";
import { preserveScrollAnchorTop, settleFollowBottom } from "../../src/agent-session/acpmux/conversation/scrollAnchor";
import { OlderPageDelay } from "../../src/agent-session/acpmux/conversation/olderPageDelay";

const row = (id: string) => ({ id });
const layout = (length: number, height = 41.25) => ({
  tops: Float64Array.from({ length }, (_, index) => index * height),
  heights: new Float64Array(length).fill(height),
  totalHeight: length * height,
});
let rows = Array.from({ length: 1000 }, (_, index) => row(`held-${index}`));
let geometry = layout(rows.length);
let top = geometry.tops[21]! + 7.5;
for (let page = 0; page < 4; page++) {
  const older = Array.from({ length: 120 }, (_, index) => row(`page-${page}-${index}`));
  const next = [...older, ...rows];
  const placed = layout(next.length);
  let reads = 0;
  const indexed = new Proxy(next, {
    get(target, key, receiver) {
      if (typeof key === "string" && /^\d+$/.test(key)) reads++;
      return Reflect.get(target, key, receiver);
    },
  });
  const nextTop = preserveScrollAnchorTop({
    oldLayout: geometry,
    newLayout: placed,
    oldRows: rows,
    newRows: indexed,
    liveTop: top,
    anchorTop: top,
  });
  assert.equal(nextTop, top + older.length * 41.25, "fractional client offset survives each prepend");
  assert.ok(reads <= 2, `prepend used ${reads} row reads instead of direct index lookup`);
  [rows, geometry, top] = [next, placed, nextTop!];
}
// A page and a new reply can arrive together: bounded lookup near the suffix candidate.
const both = [row("older"), ...rows, row("live")];
assert.equal(
  preserveScrollAnchorTop({
    oldLayout: geometry,
    newLayout: layout(both.length),
    oldRows: rows,
    newRows: both,
    liveTop: top,
    anchorTop: top,
  }),
  top + 41.25,
);
// Row completion can replace the first visible id. The next surviving row is the fallback.
assert.equal(
  preserveScrollAnchorTop({
    oldLayout: layout(3),
    newLayout: layout(4),
    oldRows: [row("gone"), row("kept"), row("tail")],
    newRows: [row("older"), row("replaced"), row("kept"), row("tail")],
    liveTop: 0,
    anchorTop: 0,
  }),
  41.25,
);
// Mixed prepend plus a removal below the anchor has a net shift that is not the anchor shift.
const mixedOld = Array.from({ length: 200 }, (_, index) => row(`mixed-${index}`));
const mixedNew = [
  ...Array.from({ length: 120 }, (_, index) => row(`older-${index}`)),
  ...mixedOld.slice(0, 140),
  ...mixedOld.slice(180),
];
const mixedTop = layout(200).tops[100]!;
assert.equal(
  preserveScrollAnchorTop({
    oldLayout: layout(mixedOld.length),
    newLayout: layout(mixedNew.length),
    oldRows: mixedOld,
    newRows: mixedNew,
    liveTop: mixedTop,
    anchorTop: mixedTop,
  }),
  mixedTop + 120 * 41.25,
);
for (const growth of [1, 2, 3, 4, 20]) {
  const node = { scrollHeight: 1000, clientHeight: 600, scrollTop: 400 };
  node.scrollHeight += growth;
  assert.equal(settleFollowBottom(node), true);
  assert.equal(node.scrollTop, node.scrollHeight - node.clientHeight, "late measurement reaches the exact DOM end");
  assert.equal(settleFollowBottom(node), false, "a settled end schedules no more work");
  node.scrollTop -= 0.25;
  assert.equal(settleFollowBottom(node), true);
  assert.equal(node.scrollTop, node.scrollHeight - node.clientHeight, "fractional residual also settles exactly");
}
const delay = new OlderPageDelay();
const cancelled = delay.wait(60_000);
delay.cancel();
assert.equal(await cancelled, false, "session switch/close releases and cancels a pending backoff");
const replaced = delay.wait(60_000);
const ready = delay.wait(0);
assert.equal(await replaced, false);
assert.equal(await ready, true);
delay.cancel();
console.log(
  "PASS: four prepends, bounded indexing, mixed ends, replaced anchor, five late bottom measurements, retry cancellation",
);
