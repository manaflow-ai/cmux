// The Unsent changes strip: every change whose outcome is unknown, with Retry and Discard, whatever
// the layout shows (an unsent archive's row may be out of view).
import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { createStrings } from "../shared/i18n";
import table from "./generated/strings.json";
import { MockTasksProvider } from "./mockProvider";
import { TasksStore } from "./store";
import { UnsentStrip } from "./TasksPage";
import { TasksOps } from "./types";

const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();
let dom: JSDOM | null = null;
let root: Root | null = null;
const tick = () => new Promise((resolve) => setTimeout(resolve, 0));

afterEach(() => {
  act(() => root?.unmount());
  root = null;
  dom?.window.close();
  dom = null;
  for (const [key, value] of saved) scope[key] = value;
  saved.clear();
});

async function mountWithUnsentArchive() {
  dom = new JSDOM('<!doctype html><html><body><main id="root"></main></body></html>', { url: "http://localhost/" });
  for (const key of [
    "window",
    "document",
    "navigator",
    "HTMLElement",
    "Element",
    "Node",
    "MouseEvent",
    "IS_REACT_ACT_ENVIRONMENT",
  ])
    saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    MouseEvent: dom.window.MouseEvent,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  const provider = new MockTasksProvider();
  let key = 0;
  const store = new TasksStore(provider, { newKey: () => `k${++key}`, schedule: () => () => {}, visible: () => true });
  store.subscribe(() => {});
  await store.start();
  await tick();
  provider.failNext.push({ code: "cmux.protocol.timeout" });
  store.archive("task_3");
  await tick();
  const strings = createStrings(table, ["en"]);
  root = createRoot(dom.window.document.getElementById("root")!);
  const render = () =>
    act(() => root!.render(<UnsentStrip store={store} state={store.getSnapshot()} strings={strings} />));
  store.subscribe(render);
  render();
  const strip = () => dom!.window.document.querySelector(".tasks-unsent-strip");
  const button = (name: string) =>
    [...dom!.window.document.querySelectorAll("button")].find((candidate) => candidate.textContent === name)!;
  return { store, provider, strip, button };
}

test("an unsent archive is listed with its task key and action", async () => {
  const { store, strip } = await mountWithUnsentArchive();
  const taskKey = store.getSnapshot().mirror.tasks.get("task_3")!.key;
  expect(strip()?.textContent).toContain("Unsent changes");
  expect(strip()?.textContent).toContain(taskKey);
  expect(strip()?.textContent).toContain("Archive");
});

test("Retry in the strip sends the archive again with its key; it then leaves the strip", async () => {
  const { provider, strip, button } = await mountWithUnsentArchive();
  await act(async () => {
    button("Retry").click();
    await tick();
    await tick();
  });
  const archives = provider.calls.filter((call) => call.op === TasksOps.archive);
  expect(archives.map((call) => call.params.idempotency_key)).toEqual(["k1", "k1"]);
  expect(strip()).toBeNull();
});

test("Discard in the strip drops the change and leaves the row as it was", async () => {
  const { store, provider, strip, button } = await mountWithUnsentArchive();
  act(() => button("Discard").click());
  expect(strip()).toBeNull();
  expect(store.getSnapshot().shown.some((t) => t.id === "task_3")).toBe(true);
  expect(provider.calls.filter((call) => call.op === TasksOps.archive).length).toBe(1);
});
