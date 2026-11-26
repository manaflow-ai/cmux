// The Cloud page's machine rows render only when their own machine changed: a minute passing
// redraws the running cost lines alone (each keeps its own clock) and neither the list nor a row,
// the mirror's rebuilt rows over unchanged machines draw nothing, one machine's event draws its row
// alone, and a selection draws the two rows whose selection flipped. Counted from React's commits
// (support/rowRenders.ts), not from the rows.
import { createRoot, rowRenders } from "./support/rowRenders";
import { afterAll, beforeAll, expect, jest, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { MachineRow } from "../src/pages/cloud/model";
import type { CloudMachine } from "../src/pages/cloud/ops";
import type { Strings } from "../src/pages/shared/i18n";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
  // The selected row reveals itself; jsdom has no scrolling.
  window.HTMLElement.prototype.scrollIntoView = () => {};
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

const NOW = Date.UTC(2026, 10, 18, 12, 0, 30);
// Keys as words, with the running time spelled out so a test can read it.
const strings: Strings = {
  language: "en",
  t: (key) => (key === "cost.running" ? "Running {duration}" : key),
  format: (key) => key,
};

// Every machine runs: each row's cost line reads "Running Nm" and moves each minute.
const machines = (n: number, name = (index: number) => `box-${index}`): CloudMachine[] =>
  Array.from(
    { length: n },
    (_, index) =>
      ({
        id: `m${index}`,
        name: name(index),
        status: "running",
        running_since: NOW - (index + 1) * 60_000,
        hourly_rate_usd: 0.26,
      }) as CloudMachine,
  );

// The mirror rebuilds every row object on each event (model.ts visibleRows).
const rowsOf = (list: CloudMachine[]): MachineRow[] =>
  list.map((machine) => ({ id: machine.id, title: machine.name ?? machine.id, status: machine.status, machine }));

const noop = () => {};
const actions = { onSelect: noop, onOpen: noop, onPause: noop, onResume: noop, onKeep: noop, onDismissNotice: noop };

async function mount(rows: MachineRow[], selection?: string) {
  const { MachineList } = await import("../src/pages/cloud/MachineList");
  const render = (next: MachineRow[], selected?: string, dismissed?: ReadonlySet<string>) =>
    act(() =>
      root!.render(
        <MachineList
          rows={next}
          layout="rows"
          selection={selected}
          strings={strings}
          {...(dismissed ? { dismissed } : {})}
          {...actions}
        />,
      ),
    );
  act(() => root?.unmount());
  rowRenders.clear();
  root = createRoot(host);
  render(rows, selection);
  return render;
}

for (const n of [100, 1_000]) {
  test(`a minute passing redraws the ${n} cost lines, not the list or its rows`, async () => {
    jest.useFakeTimers({ now: NOW });
    try {
      await mount(rowsOf(machines(n)));
      expect(rowRenders.count("MachineItem")).toBe(n);
      expect(host.querySelector(".cloud-machine-subtitle")?.textContent).toContain("1m");
      rowRenders.reset();
      await act(async () => void jest.advanceTimersByTime(61_000));
      expect(rowRenders.count("MachineList")).toBe(0);
      expect(rowRenders.count("MachineItem")).toBe(0);
      expect(rowRenders.count("MachineTimes")).toBe(n);
      expect(host.querySelector(".cloud-machine-subtitle")?.textContent).toContain("2m");
    } finally {
      jest.useRealTimers();
    }
  });

  test(`rebuilt rows over ${n} unchanged machines draw nothing; one machine's change draws its row`, async () => {
    const list = machines(n);
    const render = await mount(rowsOf(list));
    rowRenders.reset();
    render(rowsOf(list));
    expect(rowRenders.count("MachineItem")).toBe(0);
    const renamed = list.map((machine, index) => (index === 9 ? { ...machine, name: "renamed" } : machine));
    render(rowsOf(renamed));
    expect(rowRenders.count("MachineItem")).toBe(1);
    expect(host.textContent).toContain("renamed");
  });

  test(`moving the selection among ${n} machines draws the two rows it moved between`, async () => {
    const list = machines(n);
    const render = await mount(rowsOf(list), "m3");
    rowRenders.reset();
    render(rowsOf(list), "m4");
    expect(rowRenders.count("MachineItem")).toBe(2);
    expect(host.querySelector('[aria-selected="true"] .cloud-machine-title')?.textContent).toBe("box-4");
  });
}

test("dismissing one machine's notice draws that row alone", async () => {
  const { noticeKey } = await import("../src/pages/cloud/retention");
  // Every machine is paused with a notice before an automatic delete.
  const list = machines(100).map(
    (machine, index) =>
      ({
        ...machine,
        status: "paused",
        running_since: undefined,
        evict_at: NOW + (index + 3) * 86_400_000,
        notice: { kind: "heads_up", at: NOW - 1_000, delete_at: NOW + (index + 3) * 86_400_000 },
      }) as CloudMachine,
  );
  const rows = rowsOf(list);
  const render = await mount(rows);
  expect(host.querySelectorAll(".cloud-machine-notice").length).toBe(100);
  rowRenders.reset();
  render(rows, undefined, new Set([noticeKey("m7", NOW - 1_000)]));
  expect(rowRenders.count("MachineItem")).toBe(1);
  expect(host.querySelectorAll(".cloud-machine-notice").length).toBe(99);
});

test("a full relist whose machines did not change draws no row", async () => {
  const { keptMachines } = await import("../src/pages/cloud/model");
  const list = machines(100);
  const render = await mount(rowsOf(list));
  rowRenders.reset();
  // Every machine a new object, as a relist's JSON is; one of them renamed.
  const relisted = structuredClone(list).map((machine, index) =>
    index === 2 ? { ...machine, name: "renamed" } : machine,
  );
  render(rowsOf(keptMachines(list, relisted)));
  expect(rowRenders.count("MachineItem")).toBe(1);
});
