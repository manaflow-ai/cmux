// The right sidebar's Machines section (cmux-page://cmux.machines/) over a fake host (ported from the
// Swift MachineSectionViewTests and JoinedMachineRowsTests' row checks): it shows the host's
// snapshot and each one the stream sends, New Workspace runs only on a connected (and, for a joined
// machine, linked) row, the "…" and right-click open the app's native menus with the row they
// opened on, an open menu keeps the row's actions shown, a running change shows a spinner in the
// "…" place, and a failed one says so in the caption.
import { afterAll, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { createStrings } from "../src/pages/shared/i18n";
import table from "../src/pages/machines/generated/strings.json";
import { MachinesSection } from "../src/pages/machines/MachinesSection";
import { MockMachinesProvider, joinedRows, sampleRows, sampleSnapshot } from "../src/pages/machines/mockProvider";
import { MachinesStore } from "../src/pages/machines/store";
import type { MachinesSnapshot } from "../src/pages/machines/types";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "MouseEvent", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;
const strings = createStrings(table, ["en"]);

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    MouseEvent: window.MouseEvent,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.getElementById("root")!;
});

afterAll(() => {
  act(() => root?.unmount());
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

async function mount(snapshot: MachinesSnapshot = sampleSnapshot) {
  act(() => root?.unmount());
  const provider = new MockMachinesProvider(snapshot);
  const store = new MachinesStore(provider);
  root = createRoot(host);
  await act(async () => {
    root!.render(<MachinesSection store={store} strings={strings} />);
    await store.start();
  });
  return { provider, store };
}

const rowNamed = (name: string) =>
  [...host.querySelectorAll<HTMLElement>(".machines-row")].find(
    (row) => row.querySelector(".machines-name")?.textContent === name,
  )!;
const ops = (provider: MockMachinesProvider, op: string) => provider.calls.filter((call) => call.op === op);

test("it shows the host's machines under their headers, then Add Machine…", async () => {
  await mount();
  const headers = [...host.querySelectorAll(".machines-header")].map((header) => header.textContent);
  expect(headers).toEqual(["Cloud", "SSH", "Servers", "Joined"]);
  expect(host.querySelectorAll(".machines-row")).toHaveLength(sampleRows.length + joinedRows.length);
  expect(host.querySelector(".machines-row .machines-name")?.textContent).toBe("This Mac");
  expect(host.querySelector(".machines-add")?.textContent).toBe("Add Machine…");
  // Compact: a paused machine says so at its trailing edge; a connecting one has a spinner and no word.
  expect(rowNamed("night-batch").querySelector(".machines-state-trailing")?.textContent).toBe("Paused");
  expect(rowNamed("night-batch").querySelector(".machines-spinner")).toBeNull();
  expect(rowNamed("gpu-box").querySelector(".machines-spinner")).not.toBeNull();
  expect(rowNamed("gpu-box").querySelector(".machines-state")).toBeNull();
  expect(rowNamed("linux-box").title).toBe("Last check: Keep it up to date needs attention");
});

test("a snapshot from the stream replaces the shown one", async () => {
  const { provider } = await mount();
  await act(async () => provider.push({ ...sampleSnapshot, rows: [sampleRows[0]!], style: "flat" }));
  expect(host.querySelectorAll(".machines-row")).toHaveLength(1);
  expect(host.querySelectorAll(".machines-header")).toHaveLength(0);
  expect(host.querySelector(".machines-state")?.textContent).toBe("Connected");
});

test("New Workspace runs only on a connected row; Add Machine… runs device.add", async () => {
  const { provider } = await mount();
  const connected = rowNamed("atlas-web").querySelector<HTMLButtonElement>(".machines-action")!;
  const down = rowNamed("build-host").querySelector<HTMLButtonElement>(".machines-action")!;
  expect(connected.disabled).toBe(false);
  expect(down.disabled).toBe(true);
  act(() => connected.click());
  act(() => down.click());
  act(() => host.querySelector<HTMLButtonElement>(".machines-add")!.click());
  expect(ops(provider, "cmux.machines.newWorkspace").map((call) => call.params)).toEqual([
    { machine: "fixture-cloud-1" },
  ]);
  expect(ops(provider, "cmux.machines.addMachine")).toHaveLength(1);
});

test("a joined machine needs a link for New Workspace", async () => {
  await mount();
  const linked = rowNamed("lane-vm-3");
  const mesh = rowNamed("studio-mini");
  const add = (row: HTMLElement) => [...row.querySelectorAll<HTMLButtonElement>(".machines-action")].at(-1)!;
  expect(add(linked).disabled).toBe(false);
  expect(add(mesh).disabled).toBe(true);
  expect(add(mesh).title).toBe(strings.t("machines.joined.noWorkspace"));
  expect(mesh.querySelector(".machines-state")?.textContent).toBe("Online · macOS · added by you@example.com");
});

test("the more button and a right-click open the native menus on their row, which stays revealed while open", async () => {
  const { provider, store } = await mount();
  let close: () => void = () => undefined;
  const original = provider.call.bind(provider);
  provider.call = async <R,>(op: string, params: unknown) => {
    if (op !== "cmux.machines.menu") return original<R>(op, params);
    provider.calls.push({ op, params });
    await new Promise<void>((resolve) => (close = resolve));
    return {} as R;
  };
  const linked = rowNamed("lane-vm-3");
  const more = linked.querySelector<HTMLButtonElement>(".machines-more")!;
  expect(more.getAttribute("aria-label")).toBe("More for lane-vm-3");
  await act(async () => {
    more.dispatchEvent(new window.MouseEvent("mousedown", { bubbles: true, button: 0 }));
  });
  expect(ops(provider, "cmux.machines.menu").at(-1)?.params).toMatchObject({ row: "ssh-lane", menu: "joined" });
  expect(rowNamed("lane-vm-3").hasAttribute("data-menu-open")).toBe(true);
  await act(async () => close());
  expect(rowNamed("lane-vm-3").hasAttribute("data-menu-open")).toBe(false);
  await act(async () => {
    rowNamed("atlas-web").dispatchEvent(
      new window.MouseEvent("contextmenu", { bubbles: true, clientX: 30, clientY: 40 }),
    );
  });
  expect(ops(provider, "cmux.machines.menu").at(-1)?.params).toEqual({
    row: "fixture-cloud-1",
    menu: "row",
    x: 30,
    y: 40,
  });
  await act(async () => close());
  expect(store.getSnapshot().menuOpen).toBeUndefined();
});

test("a running change shows a spinner in the more button's place; a failed one says so", async () => {
  await mount({ ...sampleSnapshot, busy: ["m_gpu"], failed: { m_lane: "rotate" }, openMenu: "m_mini" });
  const busy = rowNamed("gpu-west");
  expect(busy.querySelector(".machines-more")).toBeNull();
  expect(busy.querySelector(".machines-spinner")).not.toBeNull();
  const failed = rowNamed("lane-vm-3").querySelector(".machines-state")!;
  expect(failed.hasAttribute("data-failed")).toBe(true);
  expect(failed.textContent).toContain("rotate");
  // The capture fixture's open menu lights its row as a real open menu does.
  expect(rowNamed("studio-mini").hasAttribute("data-menu-open")).toBe(true);
});
