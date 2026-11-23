import { act } from "react";
import { afterAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { MockCloudProgressProvider, SAMPLE_ASKS, sampleState } from "./mockProvider";
import { CloudProgressStore, elapsedClock, stageKey, stepMarks } from "./store";
import { CloudProgressOps } from "./types";
import { teardownDom } from "../../../test/support/domTeardown";

const dom = new JSDOM("<!doctype html><html><body></body></html>", { url: "http://localhost/" });
const globals = globalThis as Record<string, unknown>;
const replacements = {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  HTMLButtonElement: dom.window.HTMLButtonElement,
  Element: dom.window.Element,
  Node: dom.window.Node,
  // The `line` arm's steps open on a failure (Base UI's transition reads a frame).
  requestAnimationFrame:
    dom.window.requestAnimationFrame?.bind(dom.window) ?? ((run: () => void) => setTimeout(run, 0)),
  cancelAnimationFrame: dom.window.cancelAnimationFrame?.bind(dom.window) ?? clearTimeout,
  IS_REACT_ACT_ENVIRONMENT: true,
};
const saved = Object.keys(replacements).map((key) => [key, key in globals, globals[key]] as const);
Object.assign(globals, replacements);
const { createRoot } = await import("react-dom/client");
const { CloudProgressPage } = await import("./CloudProgressPage");
const strings = createStrings(table, ["en"]);
const settle = async () => {
  for (let i = 0; i < 12; i++) await Promise.resolve();
};

afterAll(async () => {
  await teardownDom(saved, { window: dom.window, scope: globals });
});

test("each step is done before the current one, the failed one is marked, and paused spins none", () => {
  expect(stepMarks(sampleState("booting"))).toEqual(["done", "done", "current", "next", "next"]);
  expect(stepMarks(sampleState("ready"))).toEqual(["done", "done", "done", "done", "done"]);
  expect(stepMarks(sampleState("failed", { step: 2 }))).toEqual(["done", "done", "failed", "next", "next"]);
  expect(stepMarks(sampleState("paused", { step: 3 }))).toEqual(["done", "done", "done", "next", "next"]);
});

test("the elapsed clock and the idle pause's own words", () => {
  expect(elapsedClock(5_400)).toBe("0:05");
  expect(elapsedClock(90_000)).toBe("1:30");
  expect(stageKey({ stage: "paused", idle: true })).toBe("pausedIdle");
  expect(stageKey({ stage: "paused", idle: false })).toBe("paused");
  for (const stage of ["requesting", "creating", "booting", "connecting", "ready", "paused", "pausedIdle"]) {
    expect(strings.t(`cloudProgress.stage.${stage}`)).not.toBe(`cloudProgress.stage.${stage}`);
  }
});

test("a change event reads the state again, and a reply older than a newer read is dropped", async () => {
  const provider = new MockCloudProgressProvider({ state: sampleState("creating") });
  const store = new CloudProgressStore(provider, () => 1_000);
  await store.start();
  expect(store.getSnapshot().state?.stage).toBe("creating");
  expect(store.getSnapshot().receivedAt).toBe(1_000);
  (provider as unknown as { update(state: unknown): void }).update(sampleState("booting"));
  await settle();
  expect(store.getSnapshot().state?.stage).toBe("booting");
  store.stop();
});

test("a failure shows its reason and buttons in the room they kept; Retry goes to the host", async () => {
  const calls: string[] = [];
  const provider = new MockCloudProgressProvider({ state: sampleState("connecting") });
  const original = provider.call.bind(provider);
  provider.call = async <R,>(op: string) => {
    calls.push(op);
    return original<R>(op);
  };
  const store = new CloudProgressStore(provider);
  const host = document.createElement("div");
  document.body.append(host);
  const root = createRoot(host);
  await act(async () => {
    root.render(<CloudProgressPage store={store} strings={strings} />);
    await store.start();
  });
  const actions = host.querySelector(".cloud-progress__actions")!;
  expect(actions).not.toBeNull();
  expect(actions.hasAttribute("data-shown")).toBe(false);
  expect(host.querySelector(".cloud-progress__note")!.hasAttribute("data-hidden")).toBe(false);

  await act(async () => {
    (provider as unknown as { update(state: unknown): void }).update(sampleState("failed", { step: 3 }));
    await settle();
  });
  // The same element, now shown: nothing was inserted above or below it.
  expect(host.querySelector(".cloud-progress__actions")).toBe(actions);
  expect(actions.hasAttribute("data-shown")).toBe(true);
  expect(host.querySelector(".cloud-progress__detail")!.textContent).toContain("cmux-tui answered");
  expect(host.querySelector(".cloud-progress__note")!.hasAttribute("data-hidden")).toBe(true);
  const labels = [...actions.querySelectorAll("button")].map((button) => button.textContent);
  expect(labels).toEqual(["Retry", "Copy Error", "Dismiss"]);

  await act(async () => {
    actions.querySelector("button")!.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true }));
    await settle();
  });
  expect(calls).toContain(CloudProgressOps.retry);
  await act(async () => root.unmount());
  store.stop();
});

test("a paused machine offers Resume and no Copy Error", async () => {
  const store = new CloudProgressStore(new MockCloudProgressProvider({ state: sampleState("paused", { idle: true }) }));
  const host = document.createElement("div");
  document.body.append(host);
  const root = createRoot(host);
  await act(async () => {
    root.render(<CloudProgressPage store={store} strings={strings} />);
    await store.start();
  });
  const labels = [...host.querySelectorAll(".cloud-progress__actions button")].map((button) => button.textContent);
  expect(labels).toEqual(["Resume", "Dismiss"]);
  expect(host.querySelector(".cloud-progress__detail")!.textContent).toContain("idle");
  await act(async () => root.unmount());
  store.stop();
});

test("a question takes the buttons' place, and its answer carries its id", async () => {
  const calls: { op: string; params: unknown }[] = [];
  const provider = new MockCloudProgressProvider({
    state: sampleState("requesting", { ask: SAMPLE_ASKS.createRequest }),
  });
  const original = provider.call.bind(provider);
  provider.call = async <R,>(op: string, params?: unknown) => {
    calls.push({ op, params });
    return original<R>(op, params);
  };
  const store = new CloudProgressStore(provider);
  const host = document.createElement("div");
  document.body.append(host);
  const root = createRoot(host);
  await act(async () => {
    root.render(<CloudProgressPage store={store} strings={strings} />);
    await store.start();
  });
  const actions = host.querySelector(".cloud-progress__actions")!;
  expect(actions.getAttribute("data-ask")).toBe("createRequest");
  expect([...actions.querySelectorAll("button")].map((button) => button.textContent)).toEqual(["Create", "Cancel"]);
  expect(host.querySelector(".cloud-progress__detail")!.textContent).toContain("An agent asked");
  expect(host.querySelector(".cloud-progress__note")!.hasAttribute("data-hidden")).toBe(true);

  await act(async () => {
    actions.querySelectorAll("button")[1]!.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true }));
    await settle();
  });
  expect(calls.find((call) => call.op === CloudProgressOps.answer)?.params).toEqual({
    id: "ask-create",
    accept: false,
  });
  // Answered: the same buttons element goes back to hidden, nothing moved.
  expect(host.querySelector(".cloud-progress__actions")).toBe(actions);
  expect(actions.hasAttribute("data-shown")).toBe(false);
  await act(async () => root.unmount());
  store.stop();
});
