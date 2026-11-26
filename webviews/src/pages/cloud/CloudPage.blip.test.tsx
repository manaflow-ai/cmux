// A Cloud service blip on one of the page's reads (the account read, the machine list) is read again
// on its own (store.ts `readAgainLater`, 1 s doubling to 10 s) and the page says nothing until it
// lasts (Leo, 2026-11-14: "i also want all our connectivity stuff to shut the fuck up"): a retryable
// answer that heals within the grace shows nothing; one that keeps failing shows one quiet line,
// with no button (Leo, 2026-11-22: "vacuous decisions like that should be just done").
import { act } from "react";
import { afterAll, expect, jest, test } from "bun:test";
import { JSDOM } from "jsdom";
import { createStrings } from "../shared/i18n";
import { pageError } from "../shared/pageClient";
import { CloudPage } from "./CloudPage";
import table from "./generated/strings.json";
import { MockCloudProvider, sampleMachines } from "./mockProvider";
import { CloudOps } from "./ops";
import { CloudStore } from "./store";
import { teardownDom } from "../../../test/support/domTeardown";

const dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/" });
const globals = globalThis as Record<string, unknown>;
const replacements = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(replacements).map((key) => [key, key in globals, globals[key]] as const);
Object.assign(globals, replacements);
const { createRoot } = await import("react-dom/client");
const strings = createStrings(table);
const settle = async () => {
  for (let i = 0; i < 30; i++) await Promise.resolve();
};

afterAll(async () => {
  jest.useRealTimers();
  await teardownDom(saved, { window: dom.window, scope: globals });
});

/** The Cloud service answers `op` with a retryable upstream error `failures` times, then as usual. */
class BlipProvider extends MockCloudProvider {
  constructor(
    private readonly op: string,
    private failures: number,
  ) {
    super();
  }
  override async call<R>(op: string, params: unknown): Promise<R> {
    if (op === this.op && this.failures > 0) {
      this.failures -= 1;
      throw pageError("cmux.cloud.upstream_error", "The Cloud service did not answer.", true);
    }
    return super.call<R>(op, params);
  }
  failuresLeft(count: number): void {
    this.failures = count;
  }
}

async function run(op: string, failures: number, ms: number) {
  jest.useFakeTimers();
  const store = new CloudStore(new BlipProvider(op, failures));
  const element = document.createElement("div");
  document.body.append(element);
  const root = createRoot(element);
  let alerted = false;
  let stillTrying = false;
  await act(async () => root.render(<CloudPage store={store} strings={strings} />));
  for (let t = 0; t <= ms; t += 100) {
    await act(async () => {
      await settle();
      jest.advanceTimersByTime(100);
      await settle();
    });
    if (element.querySelector('[role="alert"]')) alerted = true;
    if (element.querySelector(".cloud-still-trying")) stillTrying = true;
  }
  const titles = [...element.querySelectorAll(".cloud-machine-title")].map((node) => node.textContent);
  const shownButtons = element.querySelectorAll("button").length;
  await act(async () => root.unmount());
  element.remove();
  jest.useRealTimers();
  const buttons = shownButtons;
  return { alerted, stillTrying, buttons, titles, store };
}

for (const op of [CloudOps.authStatus, CloudOps.machineList]) {
  test(`a blip on ${op} that heals within the retries shows nothing, then the machines`, async () => {
    const { alerted, stillTrying, titles, store } = await run(op, 2, 10_000);
    expect(alerted).toBe(false);
    expect(stillTrying).toBe(false);
    expect(titles).toHaveLength(sampleMachines().length);
    expect(store.getSnapshot().error).toBeUndefined();
  });

  test(`a ${op} failure that keeps coming says so in one quiet line, with no button`, async () => {
    const { alerted, stillTrying, buttons } = await run(op, 100, 30_000);
    expect(alerted).toBe(false);
    expect(stillTrying).toBe(true);
    expect(buttons).toBe(0);
  });
}

test("another account whose list blips is read again on its own until its machines show", async () => {
  jest.useFakeTimers();
  const turn = async () => {
    for (let i = 0; i < 60; i++) await Promise.resolve();
  };
  // One blip spends a step of the backoff; another user signs in before it runs, and that account's
  // list blips three times. The backoff never gives up (1, 2, 4, 8 s): a spent step only lengthens
  // the next wait, so the new account's machines come up on their own with no button to press.
  const provider = new BlipProvider(CloudOps.machineList, 1);
  const store = new CloudStore(provider);
  const stop = store.subscribe(() => undefined);
  try {
    await turn();
    provider.failuresLeft(3);
    provider.switchUser("user_2", sampleMachines());
    for (let t = 0; t < 20_000; t += 100) {
      jest.advanceTimersByTime(100);
      await turn();
    }
    expect(store.getSnapshot().error).toBeUndefined();
    expect(store.getSnapshot().connection).toBe("connected");
    expect(store.getSnapshot().machines).toHaveLength(sampleMachines().length);
  } finally {
    stop();
    jest.useRealTimers();
  }
});
