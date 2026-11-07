// l10n-allow-file: test fixtures.
// Leo 2026-11-07, on the sidebar's "Updated to Nightly" card: "what if you could, like, drag around
// the updated to nightly, and you can drag that up to the top if you wanted to?"
//
// The card drags with the toasts' anchors and drag (ui/anchors.ts): up or down past the slop it
// follows the pointer (across, it still selects its words); let go, it settles at the nearer of its
// two places and that place is remembered; flicked or dropped past the sidebar's edge it closes the
// way its x does. The page reports the drag to the sidebar host, which moves the card's view.
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import { anchorMemory } from "../src/ui/anchors";
import type { UpdateHighlights } from "../src/pages/changelog/updateHighlights";
import {
  dragBox,
  pressCard,
  rememberedRow,
  rememberRow,
  rowOffset,
  shownOffset,
  RUBBER_LEAN,
  type CardDragHost,
  type CardPlace,
  type CardRow,
} from "../src/pages/changelog/updatedCardDrag";

const atBottom: CardPlace = { anchor: "bottom", above: 400, below: 0 };

test("the box spans from the highest place to the lowest, around the card at its rest", () => {
  expect(dragBox(atBottom, 236, 48)).toEqual({ left: 0, top: -400, width: 236, height: 448 });
  expect(dragBox({ anchor: "top", above: 0, below: 300 }, 236, 48)).toEqual({
    left: 0,
    top: 0,
    width: 236,
    height: 348,
  });
});

test("each place's offset from the rest, and rubber leans part of the way there", () => {
  expect(rowOffset("bottom", atBottom)).toBe(0);
  expect(rowOffset("top", atBottom)).toBe(-400);
  expect(rowOffset("bottom", { anchor: "top", above: 0, below: 300 })).toBe(300);
  const held = { x: 10, y: -100 };
  expect(shownOffset("spring", held, "bottom", atBottom)).toEqual(held);
  expect(shownOffset("ghosts", held, "top", atBottom)).toEqual(held);
  const leaned = shownOffset("rubber", held, "top", atBottom);
  expect(leaned.x).toBeCloseTo(10 * (1 - RUBBER_LEAN));
  expect(leaned.y).toBeCloseTo(-100 + (-400 + 100) * RUBBER_LEAN);
});

test("the place is remembered as the toasts' anchors are, the bottom as nothing", () => {
  const items = new Map<string, string>();
  const store = {
    getItem: (key: string) => items.get(key) ?? null,
    setItem: (key: string, value: string) => void items.set(key, value),
    removeItem: (key: string) => void items.delete(key),
  };
  const memory = anchorMemory("test.", () => store);
  expect(rememberedRow(memory)).toBeUndefined();
  rememberRow("top", memory);
  expect(rememberedRow(memory)).toBe("top");
  rememberRow("bottom", memory);
  expect(items.size).toBe(0);
  expect(rememberedRow(memory)).toBeUndefined();
});

/** A card in a jsdom page, its rest box at (0, 400) 236 x 48, and a host that records the drag. */
function stage() {
  const dom = new JSDOM(
    "<!doctype html><section><div class=rest><span class=words>Updated</span><button>x</button></div></section>",
  );
  const document = dom.window.document;
  const section = document.querySelector("section") as HTMLElement;
  const rest = document.querySelector(".rest") as HTMLElement;
  rest.getBoundingClientRect = () =>
    ({ left: 0, top: 400, width: 236, height: 48, right: 236, bottom: 448 }) as DOMRect;
  const log: string[] = [];
  const host: CardDragHost = {
    place: () => atBottom,
    move: (offset) => log.push(`move ${Math.round(offset.x)},${Math.round(offset.y)}`),
    drop: (row: CardRow, offset) => log.push(`drop ${row} ${Math.round(offset.x)},${Math.round(offset.y)}`),
    dismiss: () => log.push("dismiss"),
  };
  const scope = globalThis as Record<string, unknown>;
  const savedElement = scope.HTMLElement;
  scope.HTMLElement = dom.window.HTMLElement;
  const pointer = (type: string, x: number, y: number, at: number, target: Element = section, buttons = 1) => {
    const event = new dom.window.Event(type, { bubbles: true });
    for (const [key, value] of Object.entries({
      button: 0,
      buttons,
      pointerId: 1,
      clientX: x,
      clientY: y,
      screenX: x,
      screenY: y,
      timeStamp: at,
    }))
      Object.defineProperty(event, key, { value });
    if (type === "pointerdown") {
      Object.defineProperty(event, "currentTarget", { value: section });
      Object.defineProperty(event, "target", { value: target });
      pressCard(rest, event as unknown as PointerEvent, host, "spring", () => log.push("start"));
    } else target.dispatchEvent(event);
  };
  return {
    section,
    log,
    pointer,
    outside: document.body,
    words: document.querySelector(".words")!,
    button: document.querySelector("button")!,
    close: () => {
      scope.HTMLElement = savedElement;
      dom.window.close();
    },
  };
}

test("a press dragged up past the middle settles at the top, slowly enough not to fling", () => {
  const { log, pointer, section, close } = stage();
  try {
    pointer("pointerdown", 100, 420, 0);
    pointer("pointermove", 100, 410, 100);
    expect(section.dataset.dragging).toBe("");
    for (let step = 1; step <= 20; step++) pointer("pointermove", 100, 410 - step * 15, 100 + step * 100);
    pointer("pointerup", 100, 110, 2200);
    expect(log[0]).toBe("start");
    expect(log).toContain("move 0,-10");
    expect(log.at(-1)).toBe("drop top 0,-310");
    expect(section.dataset.dragging).toBeUndefined();
  } finally {
    close();
  }
});

test("a small drag settles back at its own place; a flick closes the card", () => {
  const { log, pointer, close } = stage();
  try {
    pointer("pointerdown", 100, 420, 0);
    for (let step = 1; step <= 4; step++) pointer("pointermove", 100, 420 - step * 10, step * 100);
    pointer("pointerup", 100, 380, 500);
    expect(log.at(-1)).toBe("drop bottom 0,-40");
    log.length = 0;
    pointer("pointerdown", 100, 420, 1000);
    pointer("pointermove", 100, 410, 1010);
    pointer("pointermove", 100, 350, 1030);
    pointer("pointerup", 100, 300, 1040);
    expect(log.at(-1)).toBe("dismiss");
  } finally {
    close();
  }
});

test("dropped past the sidebar's edge, the card closes", () => {
  const { log, pointer, close } = stage();
  try {
    pointer("pointerdown", 100, 420, 0);
    for (let step = 1; step <= 10; step++) pointer("pointermove", 100, 420 + step * 10, step * 100);
    pointer("pointerup", 100, 520, 1100);
    expect(log.at(-1)).toBe("dismiss");
  } finally {
    close();
  }
});

test("a press moved across the line selects the words, and a press on a button stays a click", () => {
  const { log, pointer, section, button, close } = stage();
  try {
    pointer("pointerdown", 100, 420, 0);
    pointer("pointermove", 130, 422, 100);
    pointer("pointermove", 100, 300, 200);
    pointer("pointerup", 100, 300, 300);
    expect(section.dataset.dragging).toBeUndefined();
    expect(log).toEqual([]);
    pointer("pointerdown", 200, 420, 400, button);
    pointer("pointermove", 200, 300, 500);
    pointer("pointerup", 200, 300, 600);
    expect(log).toEqual([]);
  } finally {
    close();
  }
});

// Review of #37669 (P2): the press listened on the card only, and took the pointer only once it had
// become a drag. A press let go off the card before the slop never heard its release, so the next
// move over the card, with no button down, started a drag.
test("a press let go off the card before the slop ends there: a later move drags nothing", () => {
  const { log, pointer, section, outside, close } = stage();
  try {
    pointer("pointerdown", 100, 420, 0);
    pointer("pointerup", 102, 470, 100, outside);
    pointer("pointermove", 100, 300, 200);
    pointer("pointermove", 100, 200, 300);
    expect(section.dataset.dragging).toBeUndefined();
    expect(log).toEqual([]);
  } finally {
    close();
  }
});

test("a press let go outside the page view sends no pointerup: a later move with no button drags nothing", () => {
  const { log, pointer, section, close } = stage();
  try {
    pointer("pointerdown", 100, 420, 0);
    // Released over the native sidebar, outside the card-sized page view: the page hears no pointerup.
    pointer("pointermove", 100, 300, 200, section, 0);
    pointer("pointermove", 100, 200, 300, section, 0);
    expect(section.dataset.dragging).toBeUndefined();
    expect(log).toEqual([]);
  } finally {
    close();
  }
});

test("a held card whose release was missed drops on the first move with no button", () => {
  const { log, pointer, section, close } = stage();
  try {
    pointer("pointerdown", 100, 420, 0);
    pointer("pointermove", 100, 400, 100);
    pointer("pointermove", 100, 380, 200, section, 0);
    pointer("pointermove", 100, 200, 300, section, 0);
    expect(section.dataset.dragging).toBeUndefined();
    expect(log.at(-1)).toBe("drop bottom 0,-40");
    expect(log.filter((line) => line.startsWith("drop"))).toHaveLength(1);
  } finally {
    close();
  }
});

test("the drop starts from where the pointer was let go, not from its last move", () => {
  const { log, pointer, close } = stage();
  try {
    pointer("pointerdown", 100, 420, 0);
    pointer("pointermove", 100, 400, 100);
    pointer("pointerup", 100, 390, 1100);
    expect(log.at(-2)).toBe("move 0,-20");
    expect(log.at(-1)).toBe("drop bottom 0,-30");
  } finally {
    close();
  }
});

const data: UpdateHighlights = {
  version: "1.0.0-nightly.4300000000001",
  build: "4300000000001",
  fromVersion: "1.0.0-nightly.4290000000001",
  fromBuild: "4290000000001",
  source: "whatsNew",
  language: "en",
  items: [{ id: "unread", title: "Unread and Running chats", summary: null, category: "new" }],
  moreCount: 0,
  changelog: { from: "1.0.0-nightly.4290000000001", to: "1.0.0-nightly.4300000000001" },
};

/** Yields macrotasks until `done` holds, at most `capMs`. */
async function until(done: () => boolean, capMs = 2000) {
  const deadline = Date.now() + capMs;
  while (!done() && Date.now() < deadline) {
    await act(async () => void (await new Promise((resolve) => setTimeout(resolve, 0))));
  }
}

// Review F1 of #37669: the page's copy decided the place, and a missing copy (the bottom is stored as
// nothing) left the host's place as it was. The page's storage does not outlive the page (its views use
// a non-persistent website data store), so its copy is never the place after a relaunch: the host's
// copy (cmux.sidebar.updatedCard.anchor) is the one that lasts, and the page's mirrors it.
test("the sidebar's surface drags only once the host says where the card rests, and the host's place wins", async () => {
  const dom = new JSDOM("<!doctype html><div id=root></div>", { url: "https://cmux.test/#/surface/updated" });
  const scope = globalThis as Record<string, unknown>;
  const globals = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    localStorage: dom.window.localStorage,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    IS_REACT_ACT_ENVIRONMENT: true,
    ResizeObserver: class {
      observe() {}
      disconnect() {}
      unobserve() {}
    },
    requestAnimationFrame: () => 0,
  };
  const saved = Object.keys(globals).map((key) => [key, key in scope, scope[key]] as const);
  Object.assign(scope, globals);
  const drags: unknown[] = [];
  let place: ((event: unknown) => void) | undefined;
  const client = {
    call: (op: string, params: unknown) => {
      if (op === "cmux.changelog.surface.get") return Promise.resolve(data);
      if (op === "cmux.changelog.surface.size") return Promise.resolve(null);
      if (op === "cmux.changelog.surface.card.drag") {
        drags.push(params);
        return Promise.resolve(null);
      }
      if (op === "cmux.changelog.list") return Promise.resolve({ builds: [], current: data.version });
      return Promise.reject(new Error(`unavailable ${op}`));
    },
    subscribe: async (stream: string, onEvent: (event: unknown) => void) => {
      if (stream === "cmux.changelog.surface.card.place") place = onEvent;
      return () => {};
    },
  };
  try {
    dom.window.localStorage.setItem("cmux.sidebar.card.updated", "top");
    const { mountUpdateSurface } = await import("../src/pages/changelog/surface");
    const host = dom.window.document.getElementById("root")!;
    await act(async () => mountUpdateSurface(host, "updated", client as never));
    const card = () => host.querySelector<HTMLElement>(".wn-updated");
    await until(() => card() !== null && place !== undefined);
    expect(card()?.dataset.drags).toBeUndefined();
    await act(async () => place!({ anchor: "bottom", above: 400, below: 0 }));
    expect(card()?.dataset.drags).toBe("");
    expect(card()?.dataset.anchor).toBe("bottom");
    // A stale page copy moves nothing; it takes the host's place.
    expect(drags).toEqual([]);
    expect(dom.window.localStorage.getItem("cmux.sidebar.card.updated")).toBeNull();
    // The host remembered the top (the page's store came up empty): the card stays there.
    await act(async () => place!({ anchor: "top", above: 0, below: 400 }));
    expect(card()?.dataset.anchor).toBe("top");
    expect(dom.window.document.documentElement.dataset.cardAnchor).toBe("top");
    expect(dom.window.localStorage.getItem("cmux.sidebar.card.updated")).toBe("top");
    expect(drags).toEqual([]);
  } finally {
    dom.window.close();
    for (const [key, had, value] of saved) {
      if (had) scope[key] = value;
      else delete scope[key];
    }
  }
});
