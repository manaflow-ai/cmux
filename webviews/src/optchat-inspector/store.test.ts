// The inspector's refresh is a page poll (p13-webui-069, MQ4b): while the page is hidden it arms no
// timer and fetches nothing, and it fetches once when the page shows again.
import { expect, test } from "bun:test";
import { FakeLifecycleDocument, FakePollClock, flushMicrotasks } from "../../test/support/pagePollFakes";
import { PageLifecycle } from "../pages/shared/pageLifecycle";
import { ApiStore } from "./store";

test("a hidden inspector fetches nothing for a minute and once on show", async () => {
  const doc = new FakeLifecycleDocument();
  const timers = new FakePollClock(flushMicrotasks);
  const fetched: string[] = [];
  const store = new ApiStore(
    async (url) => {
      fetched.push(url);
      return { ok: true };
    },
    { lifecycle: new PageLifecycle(doc), timers },
  );
  const stop = store.subscribe("/api/live", () => {}, 2000);
  await flushMicrotasks();
  expect(fetched.length).toBe(1); // the slot's first read
  await timers.advance(4000);
  expect(fetched.length).toBe(3);

  doc.hide();
  expect(timers.armed).toBe(0);
  await timers.advance(60_000);
  expect(fetched.length).toBe(3);

  doc.show();
  await flushMicrotasks();
  expect(fetched.length).toBe(4);
  expect(timers.armed).toBe(1);

  stop();
  expect(timers.armed).toBe(0);
});

test("a slot with no refresh asked for arms nothing", async () => {
  const timers = new FakePollClock();
  const store = new ApiStore(async () => ({}), { lifecycle: new PageLifecycle(new FakeLifecycleDocument()), timers });
  store.subscribe("/api/once", () => {});
  await flushMicrotasks();
  expect(timers.started).toBe(0);
});
