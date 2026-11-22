// Growth per operation (bench/growth.ts): a counter that climbs with the operations is a leak, one that only jitters
// or falls is none, and the rows it prints have a target of 0.
import { describe, expect, test } from "bun:test";
import { growthPerOp, growthRows, RESOLUTION, type GrowthSample } from "../bench/growth";

const samples = (heap: (op: number) => number, nodes: (op: number) => number, listeners = (_: number) => 40) =>
  [4, 8, 12, 16, 20, 24, 28, 32].map((op): GrowthSample => ({
    op,
    heapKb: heap(op),
    nodes: nodes(op),
    listeners: listeners(op),
  }));

describe("growthPerOp", () => {
  test("a leak of 50 KB and 12 nodes a switch is that slope", () => {
    const growth = growthPerOp(
      samples(
        (op) => 9000 + 50 * op,
        (op) => 3000 + 12 * op,
        (op) => 40 + op,
      ),
    );
    expect(growth).toEqual({ heapKbPerOp: 50, nodesPerOp: 12, listenersPerOp: 1 });
  });

  test("jitter under the resolution and a counter that falls are no growth", () => {
    const growth = growthPerOp(
      samples(
        (op) => 9000 + (op % 8 ? 3 : -3),
        (op) => 3000 - op,
      ),
    );
    expect(growth).toEqual({ heapKbPerOp: 0, nodesPerOp: 0, listenersPerOp: 0 });
  });

  test("it needs three samples", () => {
    expect(() =>
      growthPerOp(
        samples(
          () => 1,
          () => 1,
        ).slice(0, 2),
      ),
    ).toThrow();
  });
});

test("growthRows names each counter per operation with a target of 0 and its resolution as floor", () => {
  const rows = growthRows("chat_switch.churn", "switch", { heapKbPerOp: 12, nodesPerOp: 0, listenersPerOp: 0 });
  expect(rows.map((row) => [row.name, row.p95, row.target, row.floor])).toEqual([
    ["chat_switch.churn.heap_kb_per_switch", 12, 0, RESOLUTION.heapKbPerOp],
    ["chat_switch.churn.dom_nodes_per_switch", 0, 0, RESOLUTION.nodesPerOp],
    ["chat_switch.churn.listeners_per_switch", 0, 0, RESOLUTION.listenersPerOp],
  ]);
});
