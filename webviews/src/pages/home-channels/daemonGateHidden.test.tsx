// The Channels page's reconnect backoff rests while the page is hidden (MQ4b): a host
// with no daemon is asked again only while the page is shown. Hidden for a minute it is asked
// nothing; the show asks once, at once (retryBackoff.ts).
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import { createRoot } from "react-dom/client";
import { FakeLifecycleDocument, FakePollClock, flushMicrotasks } from "../../../test/support/pagePollFakes";
import type { Strings } from "../shared/i18n";
import { PageLifecycle } from "../shared/pageLifecycle";
import { DaemonGate, type HostCredential } from "./DaemonGate";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "sessionStorage", "location", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>", { url: "https://cmux.test/" });
  Object.assign(scope, {
    window,
    document: window.document,
    sessionStorage: window.sessionStorage,
    location: window.location,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.getElementById("root")!;
});

afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const strings: Strings = { language: "en", t: (key) => key, format: (key) => key };
const settle = () => act(() => flushMicrotasks(20));

test("a hidden Channels page asks its host for no endpoint for a minute; the show asks once", async () => {
  const doc = new FakeLifecycleDocument();
  const clock = new FakePollClock(settle);
  let loads = 0;
  // A daemon restarting: the host has no endpoint yet, and says to try again.
  const load = (): Promise<HostCredential> => {
    loads += 1;
    return Promise.reject(Object.assign(new Error("restarting"), { retryable: true }));
  };
  const root = createRoot(host);
  await act(async () =>
    root.render(
      <DaemonGate
        source={{ kind: "host", load }}
        strings={strings}
        seams={{ lifecycle: new PageLifecycle(doc), timers: clock }}
      >
        {() => null}
      </DaemonGate>,
    ),
  );
  await settle();
  expect(loads).toBe(1);
  expect(clock.armed).toBe(1);

  await act(async () => doc.hide());
  expect(clock.armed).toBe(0);
  await clock.advance(60_000);
  expect(loads).toBe(1);

  await act(async () => doc.show());
  await settle();
  expect(loads).toBe(2);
  await act(async () => root.unmount());
  expect(clock.armed).toBe(0);
});
