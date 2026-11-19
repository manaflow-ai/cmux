// The Machines section's rows render only when their own machine changed: the host sends every row
// on each change, and a snapshot that changes one machine draws that row alone (an unchanged one
// draws none). Counted from React's commits (support/rowRenders.ts), not from the rows.
import { createRoot, rowRenders } from "./support/rowRenders";
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { teardownDom } from "./support/domTeardown";
import type { MachineRow, MachinesSnapshot } from "../src/pages/machines/types";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.getElementById("root")!;
});

afterAll(async () => {
  act(() => root?.unmount());
  await teardownDom(saved, { scope });
});

// A fresh object per row each snapshot, as the host's JSON is.
const snapshot = (n: number, name = (index: number) => `box-${index}`): MachinesSnapshot => ({
  rows: Array.from({ length: n }, (_, index): MachineRow => ({
    id: `ssh-${index}`,
    name: name(index),
    kind: "ssh",
    isLocal: false,
    isConnected: true,
    isConnecting: false,
    health: "ok",
  })),
  style: "compact",
  busy: [],
  failed: {},
});

for (const n of [10, 100]) {
  test(`a snapshot that changes one of ${n} machines draws its row alone`, async () => {
    const { MachinesSection } = await import("../src/pages/machines/MachinesSection");
    const { MockMachinesProvider } = await import("../src/pages/machines/mockProvider");
    const { MachinesStore } = await import("../src/pages/machines/store");
    const { createStrings } = await import("../src/pages/shared/i18n");
    const table = (await import("../src/pages/machines/generated/strings.json")).default;
    const store = new MachinesStore(new MockMachinesProvider(snapshot(n)), { schedule: () => () => {} });
    act(() => root?.unmount());
    rowRenders.clear();
    root = createRoot(host);
    await act(async () => {
      root!.render(<MachinesSection store={store} strings={createStrings(table, ["en"])} />);
      await store.start();
    });
    expect(host.querySelectorAll(".machines-row").length).toBe(n);
    rowRenders.reset();
    act(() => store.land(snapshot(n)));
    expect(rowRenders.count("MachineRowView")).toBe(0);
    act(() => store.land(snapshot(n, (index) => (index === 3 ? "renamed" : `box-${index}`))));
    expect(rowRenders.count("MachineRowView")).toBe(1);
    expect(host.textContent).toContain("renamed");
  });
}
