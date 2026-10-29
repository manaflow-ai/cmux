// A reveal's wait for its row is a page poll (MQ4b): while the agent page is hidden
// it looks no more, and on show it looks once if the wait has time left. A reader who comes back
// after the wait ran out is not pulled to the row.
import { afterEach, beforeEach, expect, setSystemTime, test } from "bun:test";
import { Window } from "happy-dom";
import { REVEALED_TURN_CLASS, revealMessageWhenShown, revealTurnWhenShown } from "../src/agent-session/acpmux/links";
import { PageLifecycle } from "../src/pages/shared/pageLifecycle";
import { FakeLifecycleDocument, FakePollClock, flushMicrotasks } from "./support/pagePollFakes";

beforeEach(() => setSystemTime(new Date(1_000_000)));
afterEach(() => setSystemTime());

function transcript() {
  const document = new Window().document;
  const scrolled: string[] = [];
  const add = (attribute: "data-turn-id" | "data-row-id", id: string) => {
    const row = document.createElement("div");
    row.setAttribute(attribute, id);
    (row as unknown as { scrollIntoView: () => void }).scrollIntoView = () => void scrolled.push(id);
    document.body.appendChild(row);
    return row;
  };
  return { root: document as unknown as ParentNode, scrolled, add };
}

function page() {
  const doc = new FakeLifecycleDocument();
  const clock = new FakePollClock(flushMicrotasks);
  return { doc, clock, options: { lifecycle: new PageLifecycle(doc), timers: clock, waitMs: 5000, pollMs: 100 } };
}

test("a hidden page looks for the turn no more; its show looks once and reveals it", async () => {
  const { root, scrolled, add } = transcript();
  const { doc, clock, options } = page();
  let looks = 0;
  const counting = new Proxy(root, {
    get(target, key) {
      if (key === "querySelectorAll") looks += 1;
      const value = Reflect.get(target, key) as unknown;
      return typeof value === "function" ? (value as (...args: unknown[]) => unknown).bind(target) : value;
    },
  });
  const revealed = revealTurnWhenShown("turn-7", counting, options);
  await clock.advance(300);
  expect(looks).toBe(4);

  doc.hide();
  expect(clock.armed).toBe(0);
  setSystemTime(new Date(1_000_000 + 2000));
  await clock.advance(1700);
  expect(looks).toBe(4);

  add("data-turn-id", "turn-7");
  doc.show();
  expect(await revealed).toBe(true);
  expect(looks).toBe(5);
  expect(scrolled).toEqual(["turn-7"]);
});

test("a reader back after the wait ran out stays where they are", async () => {
  const { root, scrolled, add } = transcript();
  const { doc, clock, options } = page();
  const revealed = revealTurnWhenShown("turn-9", root, options);
  doc.hide();
  setSystemTime(new Date(1_000_000 + 30_000));
  await clock.advance(30_000);
  add("data-turn-id", "turn-9");
  doc.show();
  expect(await revealed).toBe(false);
  expect(scrolled).toEqual([]);
  expect(clock.armed).toBe(0);
});

test("a message's row drawn while the page is hidden is marked on show, not before", async () => {
  const { root, scrolled, add } = transcript();
  const { doc, clock, options } = page();
  expect(await revealMessageWhenShown("msg_01", () => "assistant-9", root, options)).toBe(true);
  doc.hide();
  const row = add("data-row-id", "assistant-9");
  await clock.advance(1000);
  expect(scrolled).toEqual([]);
  doc.show();
  expect(scrolled).toEqual(["assistant-9"]);
  expect(row.classList.contains(REVEALED_TURN_CLASS)).toBe(true);
});
