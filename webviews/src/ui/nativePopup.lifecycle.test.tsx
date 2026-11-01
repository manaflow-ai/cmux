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
  const events: NativePopupEvent[] = [];
  const hides: Record<string, unknown>[] = [];
  const anchor = { present: true };
  const host = createPopupHost(
    (call, params) => {
      if (call === "show")
        return new Promise((resolve) => shows.push({ model: params as unknown as NativePopupModel, resolve }));
      if (call === "update") updates.push(params as unknown as NativePopupModel);
      if (call === "hide") hides.push(params);
      return Promise.resolve({});
    },
    (listener) => {
      listeners.add(listener);
      return () => {
        listeners.delete(listener);
      };
    },
  );
  function Popup({ open, title, model }: { open: boolean; title: string; model: Partial<NativePopupModel> }) {
    useNativePopup({
      open,
      model: { title, side: "bottom", align: "start", width: 240, rows: [], ...model },
      anchor: () =>
        anchor.present ? { getBoundingClientRect: () => ({ left: 0, top: 0, right: 20, bottom: 20 }) } : null,
      onEvent: (event) => events.push(event),
      onDismiss: (reason) => dismissed.push(reason),
    });
    return null;
  }
  const render = (open: boolean, title = "Menu", model: Partial<NativePopupModel> = {}) =>
    act(() =>
      root!.render(
        <UiProvider container={container} popupHost={host}>
          <Popup open={open} title={title} model={model} />
        </UiProvider>,
      ),
    );
  const receive = (event: NativePopupEvent) =>
    act(() => {
      listeners.forEach((listener) => listener(event as unknown as PopupEvent));
    });
  return { render, receive, shows, updates, dismissed, events, hides, anchor };
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

test("a shown popup hides when its anchor goes away", () => {
  const h = harness();
  h.render(true);
  const first = h.shows[0]!.model;
  h.anchor.present = false;
  h.render(true, "Anchor gone");
  expect(h.hides).toEqual([{ schemaVersion: 1, id: first.id, revision: first.revision }]);
  expect(h.dismissed).toEqual(["anchor-gone"]);
  expect(h.updates).toHaveLength(0);
});

test("an opening refusal survives descriptor changes", async () => {
  const h = harness();
  h.render(true);
  h.render(true, "Updated");
  await act(async () => {
    h.shows[0]!.resolve({ shown: false });
  });
  expect(h.dismissed).toEqual([undefined]);
});

test("a prior opening refusal cannot dismiss a reopened popup", async () => {
  const h = harness();
  h.render(true);
  h.render(false);
  h.render(true);
  await act(async () => {
    h.shows[0]!.resolve({ shown: false });
  });
  expect(h.dismissed).toEqual([]);
});

test("an in-flight descriptor update keeps valid displayed actions but fences changed identities", () => {
  const h = harness();
  const rows = [{ id: "pick", kind: "action" as const, label: "A", value: "domain-a" }];
  h.render(true, "First", { rows });
  const first = h.shows[0]!.model;
  const pick: NativePopupEvent = { type: "pick", popupId: first.id, revision: first.revision, id: "pick" };
  h.render(true, "Renamed", { rows });
  h.receive(pick);
  expect(h.events).toEqual([pick]);
  h.render(true, "Replaced", { rows: [{ ...rows[0]!, value: "domain-b" }] });
  h.receive(pick);
  expect(h.events).toHaveLength(1);
  h.render(true, "Disabled ancestor", {
    rows: [{ id: "parent", kind: "submenu", label: "Parent", disabled: true, children: rows }],
  });
  h.receive({ ...pick, revision: h.updates.at(-1)!.revision });
  expect(h.events).toHaveLength(1);
  h.receive({ type: "dismiss", popupId: first.id, revision: first.revision, reason: "pick" });
  expect(h.dismissed).toEqual(["pick"]);
  h.render(false);
  h.render(true, "Reopened", { rows });
  h.receive(pick);
  expect(h.events).toHaveLength(1);
});

test("input acknowledgment survives delayed delivery and deduplicates sequence numbers", () => {
  const h = harness();
  const search = { id: "query", value: "", placeholder: "Search" };
  h.render(true, "First", { search });
  const first = h.shows[0]!.model;
  h.render(true, "In flight", { search });
  const edit: NativePopupEvent = {
    type: "search",
    popupId: first.id,
    revision: first.revision,
    id: "query",
    value: "new",
    editSequence: 2,
  };
  h.receive(edit);
  expect(h.updates.at(-1)!.search).toMatchObject({ value: "", editSequence: 0 });
  h.receive({ ...edit, value: "old", editSequence: 1 });
  h.receive(edit);
  expect(h.events).toEqual([edit]);
  h.render(true, "Echo", { search: { ...search, value: "new" } });
  expect(h.updates.at(-1)!.search?.editSequence).toBe(2);
  h.render(false);
  h.render(true, "Reopened", { search });
  expect(h.shows.at(-1)!.model.search?.editSequence).toBe(0);
  h.receive(edit);
  expect(h.events).toHaveLength(1);
});

test("explicit applied acknowledgments preserve normalized and rejected values", () => {
  const h = harness();
  const search = { id: "query", value: "", placeholder: "Search", editSequence: 7 };
  h.render(true, "Initial", { search });
  const first = h.shows[0]!.model;
  expect(first.search?.editSequence).toBe(7);
  h.receive({
    type: "search",
    popupId: first.id,
    revision: first.revision,
    id: "query",
    value: "raw",
    editSequence: 8,
  });
  expect(h.updates.at(-1)!.search).toMatchObject({ value: "", editSequence: 7 });
  h.render(true, "Normalized", { search: { ...search, value: "RAW", editSequence: 8 } });
  expect(h.updates.at(-1)!.search).toMatchObject({ value: "RAW", editSequence: 8 });
});
