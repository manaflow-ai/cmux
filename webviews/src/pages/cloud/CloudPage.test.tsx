import { afterEach, beforeEach, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { createStrings } from "../shared/i18n";
import { CloudPage } from "./CloudPage";
import table from "./generated/strings.json";
import { MockCloudProvider, sampleMachines } from "./mockProvider";
import { machineTitle } from "./model";
import { ACTION_RUN, CloudOps } from "./ops";
import { CloudStore } from "./store";
import type { MachineLayout } from "./model";

const saved: Record<string, unknown> = {};
let dom: JSDOM;
let root: Root;

beforeEach(() => {
  dom = new JSDOM("<!doctype html><html><body><div id='root'></div></body></html>", {
    url: "http://localhost/cloud/",
  });
  for (const name of ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"])
    saved[name] = (globalThis as any)[name];
  (globalThis as any).window = dom.window;
  (globalThis as any).document = dom.window.document;
  (globalThis as any).HTMLElement = dom.window.HTMLElement;
  (globalThis as any).IS_REACT_ACT_ENVIRONMENT = true;
  dom.window.HTMLElement.prototype.scrollIntoView = () => undefined;
  Object.assign(dom.window.HTMLElement.prototype, { attachEvent: () => undefined, detachEvent: () => undefined });
  root = createRoot(dom.window.document.getElementById("root")!);
});

afterEach(() => {
  act(() => root.unmount());
  for (const [name, value] of Object.entries(saved)) (globalThis as any)[name] = value;
});

async function render(provider: MockCloudProvider | null, { language = "en", layout = "rows" as MachineLayout } = {}) {
  let keys = 0;
  const store = new CloudStore(provider, { newKey: () => `k${++keys}`, layout });
  await act(async () => {
    root.render(<CloudPage store={store} strings={createStrings(table, [language])} />);
  });
  await act(async () => {
    await store.start();
  });
  await act(async () => {
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  return store;
}

const $ = (selector: string) => dom.window.document.querySelector(selector) as HTMLElement | null;
const $$ = (selector: string) => [...dom.window.document.querySelectorAll(selector)] as HTMLElement[];

function key(target: HTMLElement, keyName: string, init: KeyboardEventInit = {}) {
  target.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: keyName, bubbles: true, ...init }));
}

function typeInto(input: HTMLInputElement, value: string) {
  const setter = Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!;
  setter.call(input, value);
  input.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
}

describe("CloudPage", () => {
  test("the machine list renders from the mock provider (rows layout)", async () => {
    await render(new MockCloudProvider());
    expect($(".cloud-title")?.textContent).toBe("Cloud");
    const rows = $$(".cloud-machine.layout-rows");
    expect(rows.length).toBe(sampleMachines().length);
    expect($$(".cloud-machine-title").map((title) => title.textContent)).toEqual(
      sampleMachines().map(machineTitle),
    );
    expect($$(".cloud-status-dot").length).toBe(sampleMachines().length);
  });

  test("the cards layout renders the same machines", async () => {
    await render(new MockCloudProvider(), { layout: "cards" });
    expect($$(".cloud-machine.layout-cards").length).toBe(sampleMachines().length);
    expect($$(".cloud-machine.layout-rows").length).toBe(0);
  });

  test("Japanese strings", async () => {
    await render(new MockCloudProvider(), { language: "ja" });
    expect($(".cloud-title")?.textContent).toBe("クラウド");
  });

  test("signed out: shows sign in and calls no machine op", async () => {
    const provider = new MockCloudProvider({ signedIn: false });
    await render(provider);
    expect($(".cloud-signin-button")).not.toBeNull();
    expect($$(".cloud-machine").length).toBe(0);
    expect(provider.calls.filter((call) => call.op.startsWith("cmux.cloud.machine."))).toEqual([]);
    await act(async () => $(".cloud-signin-button")!.click());
    expect(provider.calls.some((call) => call.op === CloudOps.authSignIn)).toBe(false);
    expect(provider.calls.find((call) => call.op === ACTION_RUN)?.params).toMatchObject({
      action: CloudOps.authSignIn,
    });
    // The server does not serve sign-in yet: the page says so instead of failing.
    expect($(".cloud-signed-out .cloud-unavailable")?.textContent).toBe("Not available yet");
    expect($(".cloud-error")).toBeNull();
  });

  test("no host: the disconnected state", async () => {
    await render(null);
    expect($(".cloud-disconnected")).not.toBeNull();
  });

  test("the create sheet shows plan limits and double submit sends one create", async () => {
    const provider = new MockCloudProvider();
    await render(provider);
    await act(async () => $(".cloud-create-button")!.click());
    expect($(".cloud-create-sheet")).not.toBeNull();
    expect($(".cloud-plan-limit")?.textContent).toBeTruthy();
    await act(async () => typeInto($(".cloud-create-name") as HTMLInputElement, "sheet-box"));
    const submit = $(".cloud-create-submit")!;
    await act(async () => {
      submit.click();
      submit.click();
    });
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    expect(provider.calls.filter((call) => call.op === CloudOps.machineCreate).length).toBe(1);
  });

  test("the row delete button asks the native confirmation", async () => {
    const provider = new MockCloudProvider();
    await render(provider);
    await act(async () => $$(".cloud-machine")[0].click());
    await act(async () => $(".cloud-machine-delete")!.click());
    expect(provider.calls.some((call) => call.op === CloudOps.machineDelete)).toBe(false);
    expect(provider.calls.filter((call) => call.op === ACTION_RUN).at(-1)?.params).toMatchObject({
      action: CloudOps.machineDelete,
    });
  });

  test("plain Down and Return move the selection and open the detail", async () => {
    await render(new MockCloudProvider());
    const list = $(".cloud-machine-list")!;
    await act(async () => key(list, "ArrowDown"));
    expect($(".cloud-machine.selected .cloud-machine-title")?.textContent).toBe(machineTitle(sampleMachines()[0]));
    expect($(".cloud-detail")).not.toBeNull();
  });

  test("no keydown handler acts on Cmd or Ctrl chords", async () => {
    const provider = new MockCloudProvider();
    const store = await render(provider);
    const before = provider.calls.length;
    const snapshot = store.getSnapshot();
    const chords: KeyboardEventInit[] = [{ metaKey: true }, { ctrlKey: true }];
    const keysToTry = ["ArrowDown", "ArrowUp", "Enter", "Escape", "n", "Backspace", "Delete", " "];
    const targets = () => [
      $(".cloud-machine-list")!,
      ...$$(".cloud-machine"),
      ...$$("button"),
      dom.window.document.body,
    ];
    for (const chord of chords)
      for (const name of keysToTry) for (const target of targets()) await act(async () => key(target, name, chord));
    expect(provider.calls.length).toBe(before);
    expect(store.getSnapshot().selection).toBe(snapshot.selection);
    expect(store.getSnapshot().create).toBeUndefined();
    // The create sheet's fields ignore chords too.
    await act(async () => $(".cloud-create-button")!.click());
    for (const chord of chords)
      for (const name of ["Enter", "Escape"]) await act(async () => key($(".cloud-create-name")!, name, chord));
    expect(provider.calls.filter((call) => call.op === CloudOps.machineCreate)).toEqual([]);
    expect(store.getSnapshot().create).toBeDefined();
  });

  test("plain Return on an inline Pause button pauses and does not connect", async () => {
    const provider = new MockCloudProvider();
    await render(provider);
    const toggle = $(".cloud-machine-toggle")!;
    await act(async () => key(toggle, "Enter"));
    expect(provider.calls.some((call) => call.op === ACTION_RUN)).toBe(false);
  });

  test("Escape closes the create sheet", async () => {
    const store = await render(new MockCloudProvider());
    await act(async () => $(".cloud-create-button")!.click());
    await act(async () => key($(".cloud-create-name")!, "Escape"));
    expect(store.getSnapshot().create).toBeUndefined();
  });

  test("a watch event updates the visible list", async () => {
    const provider = new MockCloudProvider();
    await render(provider);
    await act(async () => {
      provider.emitUpsert({ id: "vm-live", provider: "freestyle", status: "running", displayName: "live-box" });
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    expect($$(".cloud-machine-title").map((title) => title.textContent)).toContain("live-box");
  });

  test("the detail shows stats and size from the catalog fields and marks sections not available yet", async () => {
    const provider = new MockCloudProvider();
    await render(provider);
    await act(async () => $$(".cloud-machine")[0].click());
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    expect($(".cloud-detail")).not.toBeNull();
    expect($(".cloud-size-spec")?.textContent).toBe("4 CPU · 8 GB memory · 64 GB disk");
    expect($$(".cloud-meter").length).toBe(3);
    // Publications, domains, network and firewall are not served by the Cloud app server yet.
    expect($$(".cloud-detail .cloud-unavailable").length).toBe(4);
    expect($(".cloud-error")).toBeNull();
    expect($$(".cloud-snapshot").length).toBeGreaterThan(0);
  });

  test("restore on a snapshot creates a machine with snapshot.restore, no confirmation", async () => {
    const provider = new MockCloudProvider();
    await render(provider);
    await act(async () => $$(".cloud-machine")[0].click());
    await act(async () => {
      await new Promise((resolve) => setTimeout(resolve, 0));
    });
    const before = $$(".cloud-machine").length;
    await act(async () => $(".cloud-snapshot-restore")!.click());
    expect(provider.calls.some((call) => call.op === ACTION_RUN)).toBe(false);
    expect(provider.calls.filter((call) => call.op === CloudOps.snapshotRestore).length).toBe(1);
    expect($$(".cloud-machine").length).toBe(before + 1);
  });
});
