// An expanded tray row's live tail is a page poll (MQ4b): while the agent page is
// hidden it reads nothing and arms no timer, and on show it waits one period before it reads again,
// since a show reads nothing in the agent page (scripts/cmux-next/check-switch-fetches.py).
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { FakeLifecycleDocument, FakePollClock } from "../../../../test/support/pagePollFakes";
import { PageLifecycle } from "../../../pages/shared/pageLifecycle";
import {
  BackgroundTaskOutputContext,
  type BackgroundTaskOutputReader,
  LIVE_TAIL_POLL_MS,
  useLiveBackgroundTaskOutput,
} from "./backgroundTaskOutput";

const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
let dom: JSDOM | undefined;
let root: Root | undefined;

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

const settle = () => act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));

function Tail({ seams }: { seams: { lifecycle: PageLifecycle; timers: FakePollClock } }) {
  const read = useLiveBackgroundTaskOutput("call-1", undefined, true, seams);
  return <output>{read.output ?? ""}</output>;
}

test("a hidden page reads no tail for a minute; its show waits one period, then reads", async () => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>");
  for (const key of ["window", "document", "IS_REACT_ACT_ENVIRONMENT"]) saved.set(key, scope[key]);
  Object.assign(scope, { window: dom.window, document: dom.window.document, IS_REACT_ACT_ENVIRONMENT: true });

  let lists = 0;
  const reader: BackgroundTaskOutputReader = {
    sessionId: "s1",
    source: {
      listProcesses: async () => {
        lists += 1;
        return { processes: [{ id: "p1", toolCallId: "call-1", state: "running" }] };
      },
      tailProcess: async () => ({ data: btoa(`line ${lists}\n`), fromByte: 0 }),
    },
  };
  const doc = new FakeLifecycleDocument();
  const seams = { lifecycle: new PageLifecycle(doc), timers: new FakePollClock(settle) };
  await act(async () => {
    root = createRoot(dom!.window.document.getElementById("root")!);
    root.render(
      <BackgroundTaskOutputContext.Provider value={reader}>
        <Tail seams={seams} />
      </BackgroundTaskOutputContext.Provider>,
    );
  });
  await settle();
  expect(lists).toBe(1);
  await seams.timers.advance(LIVE_TAIL_POLL_MS * 2);
  expect(lists).toBe(3);

  await act(async () => doc.hide());
  expect(seams.timers.armed).toBe(0);
  await seams.timers.advance(60_000);
  expect(lists).toBe(3);

  await act(async () => doc.show());
  await settle();
  expect(lists).toBe(3);
  expect(seams.timers.armed).toBe(1);
  await seams.timers.advance(LIVE_TAIL_POLL_MS);
  expect(lists).toBe(4);
  expect(dom.window.document.querySelector("output")?.textContent).toBe("line 4\n");
});
