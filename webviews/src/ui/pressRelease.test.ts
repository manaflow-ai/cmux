// watchPress: one press, followed until it ends. Each end the page can hear ends it once; an element's
// blur and a move with a button held do not; the stop removes every listener.
import { expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { watchPress, type PressEnd } from "./pressRelease";

function setup() {
  const dom = new JSDOM("<!doctype html><body><button>row</button></body>");
  const { window } = dom;
  const ends: [PressEnd, string | undefined][] = [];
  const moves: number[] = [];
  // The listeners the press adds (others in the test environment add their own to the window as
  // events first arrive), by type, listener and phase, until each is removed.
  const live = new Set<string>();
  const fns = new Map<EventListener, number>();
  const id = (type: string, fn: EventListener, capture: unknown) => {
    if (!fns.has(fn)) fns.set(fn, fns.size);
    return `${type} ${fns.get(fn)} ${capture === true || (capture as { capture?: boolean })?.capture === true}`;
  };
  let watchingNow = false;
  const add = window.addEventListener.bind(window);
  const remove = window.removeEventListener.bind(window);
  window.addEventListener = ((type: string, fn: EventListener, capture?: boolean) => {
    if (watchingNow) live.add(id(type, fn, capture));
    add(type, fn, capture);
  }) as typeof window.addEventListener;
  window.removeEventListener = ((type: string, fn: EventListener, capture?: boolean) => {
    live.delete(id(type, fn, capture));
    remove(type, fn, capture);
  }) as typeof window.removeEventListener;
  const listeners = () => live.size;
  const arm = <T>(start: () => T): T => {
    watchingNow = true;
    try {
      return start();
    } finally {
      watchingNow = false;
    }
  };
  const pointer = (type: string, init: Record<string, unknown> = {}) =>
    window.document.querySelector("button")!.dispatchEvent(
      Object.assign(new window.MouseEvent(type, { bubbles: true, buttons: 1, ...init }), {
        pointerId: (init.pointerId as number | undefined) ?? 1,
      }),
    );
  return { window, ends, moves, listeners, pointer, arm };
}

const watching = (env: ReturnType<typeof setup>, extra: { pointerId?: number } = {}) =>
  env.arm(() =>
    watchPress(env.window.document, {
      ...extra,
      move: (event) => env.moves.push(event.clientX),
      end: (how, event) => env.ends.push([how, event?.type]),
    }),
  );

const cases: [string, PressEnd, string | undefined, (env: ReturnType<typeof setup>) => void][] = [
  ["a pointerup", "up", "pointerup", (env) => env.pointer("pointerup", { buttons: 0 })],
  ["a pointercancel", "cancel", "pointercancel", (env) => env.pointer("pointercancel", { buttons: 0 })],
  ["a lost pointer capture", "lostcapture", "lostpointercapture", (env) => env.pointer("lostpointercapture")],
  ["the window's own blur", "blur", undefined, (env) => env.window.dispatchEvent(new env.window.FocusEvent("blur"))],
  ["a move with no button down", "released", "pointermove", (env) => env.pointer("pointermove", { buttons: 0 })],
];

for (const [name, how, type, end] of cases)
  test(`${name} ends the press once and removes every listener`, () => {
    const env = setup();
    watching(env);
    expect(env.listeners()).toBe(5);
    end(env);
    expect(env.ends).toEqual([[how, type]]);
    expect(env.listeners()).toBe(0);
    // Nothing after the end reaches it.
    env.pointer("pointerup", { buttons: 0 });
    env.window.dispatchEvent(new env.window.FocusEvent("blur"));
    expect(env.ends).toHaveLength(1);
  });

test("an element's blur does not end the press, nor does a move with a button held", () => {
  const env = setup();
  watching(env);
  // An element's blur reaches the window only in the capture phase; it is not the window's.
  env.window.document.querySelector("button")!.dispatchEvent(new env.window.FocusEvent("blur"));
  env.window.document.body.dispatchEvent(new env.window.FocusEvent("blur", { bubbles: true }));
  env.pointer("pointermove", { buttons: 1, clientX: 7 });
  expect(env.ends).toEqual([]);
  expect(env.moves).toEqual([7]);
  expect(env.listeners()).toBe(5);
});

test("with a pointerId, another pointer's events do not end the press; the window's blur still does", () => {
  const env = setup();
  watching(env, { pointerId: 1 });
  env.pointer("pointerup", { pointerId: 2, buttons: 0 });
  env.pointer("pointermove", { pointerId: 2, buttons: 0 });
  env.pointer("lostpointercapture", { pointerId: 2 });
  expect(env.ends).toEqual([]);
  env.window.dispatchEvent(new env.window.FocusEvent("blur"));
  expect(env.ends).toEqual([["blur", undefined]]);
});

test("the stop (an unmount) removes every listener and ends nothing", () => {
  const env = setup();
  const stop = watching(env);
  stop();
  expect(env.listeners()).toBe(0);
  env.pointer("pointerup", { buttons: 0 });
  env.window.dispatchEvent(new env.window.FocusEvent("blur"));
  expect(env.ends).toEqual([]);
  stop();
  expect(env.listeners()).toBe(0);
});

test("a mouse press follows mousemove and mouseup, and ends on a mousemove with no button down", () => {
  const env = setup();
  env.arm(() =>
    watchPress(env.window.document, {
      events: "mouse",
      move: (event) => env.moves.push(event.clientX),
      end: (how, event) => env.ends.push([how, event?.type]),
    }),
  );
  expect(env.listeners()).toBe(3);
  env.pointer("pointerup", { buttons: 0 });
  env.pointer("mousemove", { buttons: 1, clientX: 3 });
  expect(env.ends).toEqual([]);
  expect(env.moves).toEqual([3]);
  env.pointer("mousemove", { buttons: 0 });
  expect(env.ends).toEqual([["released", "mousemove"]]);
  expect(env.listeners()).toBe(0);
});

test("a mouse press ends on its mouseup", () => {
  const env = setup();
  env.arm(() =>
    watchPress(env.window.document, { events: "mouse", end: (how, event) => env.ends.push([how, event?.type]) }),
  );
  env.pointer("mouseup", { buttons: 0 });
  expect(env.ends).toEqual([["up", "mouseup"]]);
  expect(env.listeners()).toBe(0);
});
