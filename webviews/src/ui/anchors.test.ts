// The six anchors, their memory and the drag (anchors.ts): which anchor a point is nearest, the
// anchor remembered per toast kind, and a release that settles, comes back, or flings away.
import { expect, test } from "bun:test";
import { anchorMemory, anchorPoint, createDrag, nearestAnchor, type Box } from "./anchors";
import { createNoticeQueue } from "./NoticeStack";

const BOX: Box = { left: 0, top: 0, width: 900, height: 600 };

test("a point settles at the anchor whose region holds it", () => {
  expect(nearestAnchor({ x: 10, y: 10 }, BOX)).toBe("top-left");
  expect(nearestAnchor({ x: 450, y: 40 }, BOX)).toBe("top");
  expect(nearestAnchor({ x: 880, y: 250 }, BOX)).toBe("top-right");
  expect(nearestAnchor({ x: 20, y: 590 }, BOX)).toBe("bottom-left");
  expect(nearestAnchor({ x: 460, y: 400 }, BOX)).toBe("bottom");
  expect(nearestAnchor({ x: 899, y: 599 }, BOX)).toBe("bottom-right");
  // Outside the box, the nearest edge's anchor still.
  expect(nearestAnchor({ x: -50, y: 700 }, BOX)).toBe("bottom-left");
  expect(anchorPoint("top-right", BOX)).toEqual({ x: 900, y: 0 });
  expect(anchorPoint("bottom", BOX)).toEqual({ x: 450, y: 600 });
});

function memoryStore() {
  const map = new Map<string, string>();
  return {
    map,
    store: () => ({
      getItem: (key: string) => map.get(key) ?? null,
      setItem: (key: string, value: string) => void map.set(key, value),
      removeItem: (key: string) => void map.delete(key),
    }),
  };
}

test("the anchor a toast is dragged to is remembered for its kind, and the next of that kind shows there", () => {
  const { map, store } = memoryStore();
  const anchors = anchorMemory("toast.", store);
  const queue = createNoticeQueue(3, { anchors });
  const id = queue.show({ message: "Can't find dev's chat", group: "senderMissing" });
  expect(queue.snapshot()[0]!.anchor).toBe("bottom");
  queue.move(id, "top-right");
  expect(queue.snapshot()[0]!.anchor).toBe("top-right");
  expect(map.get("toast.senderMissing")).toBe("top-right");
  queue.close(id);
  // A new page's queue reads the same memory.
  const later = createNoticeQueue(3, { anchors: anchorMemory("toast.", store) });
  later.show({ message: "Can't find ops's chat", group: "senderMissing" });
  later.show({ message: "Copied." });
  expect(later.snapshot().map((entry) => entry.anchor)).toEqual(["top-right", "bottom"]);
  // Back to the bottom: the default is stored as nothing.
  later.move(later.snapshot()[0]!.spec.id, "bottom");
  expect(map.has("toast.senderMissing")).toBe(false);
});

test("a refused store remembers nothing and never throws", () => {
  const refused = anchorMemory("toast.", () => ({
    getItem: () => {
      throw new Error("denied");
    },
    setItem: () => {
      throw new Error("denied");
    },
    removeItem: () => undefined,
  }));
  expect(refused.get("x")).toBeUndefined();
  expect(() => refused.set("x", "top")).not.toThrow();
});

test("a press that never moves past the slop is a click", () => {
  const drag = createDrag({ x: 100, y: 500 }, 0);
  drag.move({ x: 102, y: 501 }, 10);
  expect(drag.dragging).toBe(false);
  expect(drag.release({ x: 102, y: 501 }, 20, BOX)).toEqual({ kind: "click" });
});

test("a slow drop settles at the nearest anchor; a flick or a drop past the edge flings it away", () => {
  const slow = createDrag({ x: 450, y: 560 }, 0);
  slow.move({ x: 600, y: 300 }, 300);
  slow.move({ x: 800, y: 60 }, 600);
  expect(slow.release({ x: 820, y: 50 }, 900, BOX)).toMatchObject({ kind: "snap", anchor: "top-right" });

  const flick = createDrag({ x: 450, y: 560 }, 0);
  flick.move({ x: 470, y: 560 }, 10);
  flick.move({ x: 520, y: 560 }, 30);
  const flung = flick.release({ x: 580, y: 560 }, 50, BOX);
  expect(flung.kind).toBe("dismiss");
  if (flung.kind === "dismiss") expect(flung.velocity.x).toBeGreaterThan(1);

  const out = createDrag({ x: 450, y: 560 }, 0);
  out.move({ x: 700, y: 580 }, 400);
  expect(out.release({ x: 960, y: 580 }, 900, BOX).kind).toBe("dismiss");
});
