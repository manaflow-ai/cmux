import { afterEach, expect, test } from "bun:test";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { UiProvider } from "./UiProvider";
import { createPopupHost, type PopupEvent } from "./popupHost";
import { useNativePopup, type NativePopupEvent, type NativePopupModel } from "./nativePopup";

let root: Root | undefined;
let dom: JSDOM | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  for (const [key, value] of saved) scope[key] = value;
  saved.clear();
  dom?.window.close();
  dom = undefined;
});

function harness() {
  dom = new JSDOM("<!doctype html><html><body><main></main></body></html>");
  for (const key of ["window", "document", "navigator", "IS_REACT_ACT_ENVIRONMENT"]) saved.set(key, scope[key]);
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  const container = dom.window.document.querySelector("main")!;
  root = createRoot(container);
  const listeners = new Set<(event: PopupEvent) => void>();
  const shows: { model: NativePopupModel; resolve: (reply: unknown) => void }[] = [];
  const updates: NativePopupModel[] = [];
  const dismissed: (string | undefined)[] = [];
  const host = createPopupHost(
    (call, params) => {
      if (call === "show") return new Promise((resolve) => shows.push({ model: params as unknown as NativePopupModel, resolve }));
      if (call === "update") updates.push(params as unknown as NativePopupModel);
      return Promise.resolve({});
    },
    (listener) => {
      listeners.add(listener);
      return () => { listeners.delete(listener); };
    },
  );
  function Popup({ open, title }: { open: boolean; title: string }) {
    useNativePopup({
      open,
      model: { title, side: "bottom", align: "start", width: 240, rows: [] },
      anchor: () => ({ getBoundingClientRect: () => ({ left: 0, top: 0, right: 20, bottom: 20 }) }),
      onEvent: () => {},
      onDismiss: (reason) => dismissed.push(reason),
    });
    return null;
  }
  const render = (open: boolean, title = "Menu") => act(() => root!.render(
    <UiProvider container={container} popupHost={host}><Popup open={open} title={title} /></UiProvider>,
  ));
  const receive = (event: NativePopupEvent) => act(() => {
    listeners.forEach((listener) => listener(event as unknown as PopupEvent));
  });
  return { render, receive, shows, updates, dismissed };
}

test("a current opening dismissal survives a descriptor update but an old opening does not", () => {
  const h = harness();
  h.render(true);
  const first = h.shows[0]!.model;
  h.render(true, "Updated");
  expect(h.updates.length).toBe(1);
  h.receive({ type: "dismiss", popupId: first.id, revision: first.revision, reason: "escape" });
  expect(h.dismissed).toEqual(["escape"]);
  h.render(false);
  h.render(true);
  h.receive({ type: "dismiss", popupId: first.id, revision: first.revision, reason: "outside" });
  expect(h.dismissed).toEqual(["escape"]);
});

test("an opening refusal survives descriptor changes", async () => {
  const h = harness();
  h.render(true);
  h.render(true, "Updated");
  await act(async () => { h.shows[0]!.resolve({ shown: false }); });
  expect(h.dismissed).toEqual([undefined]);
});

test("a prior opening refusal cannot dismiss a reopened popup", async () => {
  const h = harness();
  h.render(true);
  h.render(false);
  h.render(true);
  await act(async () => { h.shows[0]!.resolve({ shown: false }); });
  expect(h.dismissed).toEqual([]);
});
