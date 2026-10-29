// A bare #N's pull request rounds rest while the agent page is hidden (MQ4b): the
// rounds of link.inspect and pr.inspect wait on a page timeout, so a hidden page asks the host
// nothing for a minute, a show asks nothing on its turn, and the round runs one wait later.
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { setChipHost } from "../src/agent-session/acpmux/chips/host";
import { resetReferenceExistence, usePullRequestsExist } from "../src/agent-session/acpmux/chips/referenceExistence";
import { PageLifecycle } from "../src/pages/shared/pageLifecycle";
import { FakeLifecycleDocument, FakePollClock, flushMicrotasks } from "./support/pagePollFakes";
import { useDom } from "./support/unknownWrite";

const dom = useDom();
afterEach(() => {
  setChipHost(undefined);
  resetReferenceExistence();
});

const URL = "https://github.com/manaflow-ai/cmux/pull/24175";
const MINUTE = 60_000;

function Chip() {
  const exists = usePullRequestsExist([URL]);
  return <span id="chip">{exists === undefined ? "asking" : String(exists[0])}</span>;
}

/** A host still reading for the first `reading` pr.inspect asks, then naming the pull request. */
function host(reading: number) {
  const calls: string[] = [];
  setChipHost(async (method) => {
    calls.push(method);
    if (method !== "pr.inspect") return {};
    if (calls.filter((call) => call === "pr.inspect").length <= reading) return { pullRequest: null, reading: true };
    return { pullRequest: { url: URL, number: 24175 }, reading: false };
  });
  return calls;
}

const settle = () => act(() => flushMicrotasks(20));

function page(hidden = false) {
  const doc = new FakeLifecycleDocument();
  if (hidden) doc.visibilityState = "hidden";
  const clock = new FakePollClock(settle);
  resetReferenceExistence({ lifecycle: new PageLifecycle(doc), timers: clock });
  return { doc, clock };
}

test("a chip drawn on a hidden page asks the host nothing for a minute; the round runs one wait after show", async () => {
  const { doc, clock } = page(true);
  const calls = host(0);
  await dom.render(<Chip />);
  await settle();
  await clock.advance(MINUTE);
  expect(calls).toEqual([]);
  expect(clock.started).toBe(0);

  await act(async () => doc.show());
  await settle();
  expect(calls).toEqual([]);
  await clock.advance(1500);
  expect(calls).toEqual(["link.inspect", "pr.inspect"]);
  expect(dom.text("#chip")).toBe("true");
});

test("a round waiting on a host read rests while hidden and counts its wait again on show", async () => {
  const { doc, clock } = page();
  const calls = host(1);
  await dom.render(<Chip />);
  await settle();
  // The first round ran at once; the host is still reading, so the next round waits 1.5 s.
  expect(calls).toEqual(["link.inspect", "pr.inspect"]);
  expect(clock.armed).toBe(1);

  await act(async () => doc.hide());
  expect(clock.armed).toBe(0);
  await clock.advance(MINUTE);
  expect(calls.length).toBe(2);

  await act(async () => doc.show());
  await settle();
  expect(calls.length).toBe(2);
  await clock.advance(1499);
  expect(calls.length).toBe(2);
  await clock.advance(1);
  expect(calls).toEqual(["link.inspect", "pr.inspect", "link.inspect", "pr.inspect"]);
  expect(dom.text("#chip")).toBe("true");
});
