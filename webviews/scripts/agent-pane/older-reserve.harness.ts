// Deterministic geometry replay; run from the repo root with:
// bun webviews/scripts/agent-pane/older-reserve.harness.ts
// Counts arrive after the first frame, then the same rows lay out again.
// Reports geometry changes, not browser frame time.
import { minimapScale } from "../../src/agent-session/acpmux/chatMinimap/paint";
import type { AcpmuxRow } from "../../src/agent-session/acpmux/model";
import { olderReserve } from "../../src/agent-session/acpmux/conversation/olderReserve";

for (const [name, loaded, total] of [
  ["light", 10, 50],
  ["stress", 100, 5000],
] as const) {
  let kindReads = 0;
  const rows = Array.from({ length: loaded * 2 }, (_, index) => ({
    id: `row-${index}`,
    get kind() {
      kindReads += 1;
      return index % 2 === 0 ? "user" : "assistant";
    },
  })) as AcpmuxRow[];
  const input = {
    sessionId: name,
    rows,
    rowTop: (index: number) => index * 100,
    rowsHeight: rows.length * 100,
    canLoadOlder: true,
  };
  const first = olderReserve(undefined, input);
  const beforeReads = kindReads;
  const late = olderReserve(first.state, { ...input, promptCount: total });
  const firstHeight = input.rowsHeight + first.reserve;
  const lateHeight = input.rowsHeight + late.reserve;
  console.log(
    JSON.stringify({
      scenario: name,
      lateCountHeightGrowthPx: lateHeight - firstHeight,
      lateCountMinimapScaleChange: Math.abs(minimapScale(lateHeight, 500) - minimapScale(firstHeight, 500)),
      lateCountKindReads: kindReads - beforeReads,
    }),
  );
}
