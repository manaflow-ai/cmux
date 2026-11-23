// The Cloud page's Files section draws what is visible (the visible-only rule): a folder of 1,000 or
// 10,000 entries mounts the same rows and DOM nodes, a one-row scroll draws only the rows it brings
// in, and a relisting that changes one entry draws that row alone. Before, every entry was a mounted
// row, and every one drew again on each update of the machine's detail.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { MachineDetail } from "../src/pages/cloud/detail";
import type { FsEntry } from "../src/pages/cloud/ops";
import type { CloudStore } from "../src/pages/cloud/store";
import type { Strings } from "../src/pages/shared/i18n";
import { settleReact } from "./support/domTeardown";
import { mountedRowRenders } from "./support/mountedRowRenders";
import { installVirtualSizes } from "./support/virtualSizes";

const scope = globalThis as Record<string, unknown>;
const names = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "HTMLTextAreaElement",
  "Element",
  "Node",
  "Event",
  "MouseEvent",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = names.map((name) => [name, scope[name]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

/** The page body is 600 px tall; a file row is 29 px. */
const BODY = 600;
const ROW = 29;
const sizes = (element: HTMLElement) =>
  element.classList.contains("cloud-body") ? BODY : element.classList.contains("cloud-file") ? ROW : 0;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", {
    url: "http://localhost/cloud/",
    pretendToBeVisual: true,
  });
  const win = dom.window as unknown as Record<string, unknown>;
  for (const name of names) scope[name] = name === "window" ? dom.window : win[name];
  scope.IS_REACT_ACT_ENVIRONMENT = true;
  scope.getComputedStyle = dom.window.getComputedStyle.bind(dom.window);
  scope.requestAnimationFrame = (callback: FrameRequestCallback) =>
    setTimeout(() => callback(Date.now()), 0) as unknown as number;
  scope.cancelAnimationFrame = (handle: number) => clearTimeout(handle);
  // The page's stylesheet is not loaded: the body scrolls as styles.css says.
  const style = dom.window.document.createElement("style");
  style.textContent = ".cloud-body { overflow-y: auto; }";
  dom.window.document.head.append(style);
  installVirtualSizes(dom.window, sizes);
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
});

afterAll(async () => {
  await settleReact();
  dom.window.close();
  for (const [name, value] of saved) {
    if (value === undefined) delete scope[name];
    else scope[name] = value;
  }
});

const { createRoot } = await import("react-dom/client");
const { FilesSection } = await import("../src/pages/cloud/FilesSection");
const { FilesReader } = await import("../src/pages/cloud/files");
const { CloudOps } = await import("../src/pages/cloud/ops");

const strings: Strings = { language: "en", t: (key) => key, format: (key) => key };
const FOLDER = "/home/cmux";

/** A folder of `n` entries that the test can change; the real files reader lists it. */
async function mount(n: number) {
  const entries: FsEntry[] = Array.from({ length: n }, (_, index) => ({
    name: `file-${String(index).padStart(5, "0")}.txt`,
    kind: index % 10 === 0 ? "directory" : "file",
    size: index * 10,
  }));
  let detail: MachineDetail = { machine: "machine-a", loading: false };
  const draw = () =>
    root!.render(
      <div className="cloud-body">
        <FilesSection
          store={{ files } as unknown as CloudStore}
          detail={detail}
          unavailable={[]}
          transfers={[]}
          strings={strings}
        />
        <button type="button" id="after">
          after
        </button>
      </div>,
    );
  const client = {
    call: async (op: string) => {
      if (op === CloudOps.fsList) return { path: FOLDER, entries: entries.map((entry) => ({ ...entry })) };
      throw new Error(op);
    },
    subscribe: async () => () => {},
    handle: () => () => {},
  };
  const files = new FilesReader(
    client as never,
    {
      epoch: () => 0,
      get: () => detail,
      set: (next) => {
        detail = next;
        draw();
      },
      fail: () => {},
      unsupported: () => {},
      canChange: () => true,
      key: () => "k",
    },
    { watch: () => {}, add: () => {} } as never,
  );
  host = dom.window.document.getElementById("root")!;
  root = createRoot(host);
  await act(async () => draw());
  await act(async () => files.open(FOLDER));
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  return { entries, files, body: host.querySelector<HTMLElement>(".cloud-body")! };
}

const rows = () => host.querySelectorAll(".cloud-file");
// The nearest component above each row's node: the row itself once memoized, the section before.
const renders = mountedRowRenders(rows);

async function measure(n: number) {
  const { entries, files, body } = await mount(n);
  const list = host.querySelector<HTMLElement>(".cloud-files")!;
  const mounted = { rows: rows().length, nodes: list.querySelectorAll("*").length };

  const rects = { calls: 0 };
  const original = dom.window.Element.prototype.getBoundingClientRect;
  dom.window.Element.prototype.getBoundingClientRect = function (this: Element) {
    rects.calls++;
    return original.call(this);
  };
  renders.mark();
  await act(async () => {
    body.scrollTop += ROW;
    body.dispatchEvent(new dom.window.Event("scroll"));
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  const scroll = { renders: renders.since(), rects: rects.calls };
  dom.window.Element.prototype.getBoundingClientRect = original;

  // A relisting where one entry in view grew.
  entries[3] = { ...entries[3]!, size: 123_456 };
  renders.mark();
  await act(async () => files.open(FOLDER));
  await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  const change = renders.since();
  return { n, mounted, scroll, change };
}

test("a folder of 1,000 and 10,000 entries mounts the same rows, and one event draws only the rows it changed", async () => {
  const small = await measure(1_000);
  act(() => root?.unmount());
  const large = await measure(10_000);
  console.log(JSON.stringify({ small, large }));

  // Rule 1: the body's rows (600 / 29) and about one viewport each side, not the folder.
  for (const run of [small, large]) {
    expect(run.mounted.rows).toBeGreaterThan(15);
    expect(run.mounted.rows).toBeLessThanOrEqual(70);
  }
  expect(Math.abs(large.mounted.rows - small.mounted.rows)).toBeLessThanOrEqual(small.mounted.rows * 0.1);
  expect(Math.abs(large.mounted.nodes - small.mounted.nodes)).toBeLessThanOrEqual(small.mounted.nodes * 0.1);

  for (const run of [small, large]) {
    // Rule 2: a one-row scroll draws only the row it brings in.
    expect(run.scroll.renders).toBeLessThanOrEqual(2);
    // A relisting that changes one entry draws that row alone.
    expect(run.change).toBeLessThanOrEqual(1);
  }
  // Rule 3: a scroll reads no row's layout, at any length.
  expect(large.scroll.rects).toBe(small.scroll.rects);
});

test("the row with focus stays mounted while the body scrolls far past it", async () => {
  const { body } = await mount(1_000);
  const button = host.querySelectorAll<HTMLElement>(".cloud-file-name")[2]!;
  await act(async () => button.focus());
  await act(async () => {
    body.scrollTop += ROW * 400;
    body.dispatchEvent(new dom.window.Event("scroll"));
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
  expect(button.isConnected).toBe(true);
  expect(dom.window.document.activeElement).toBe(button);
  expect(rows().length).toBeLessThanOrEqual(75);
  const positions = [...rows()].map((row) => Number(row.getAttribute("aria-posinset")));
  // The first entry, the focused one and its neighbours, the window far below, the last entry.
  expect(positions.slice(0, 4)).toEqual([1, 2, 3, 4]);
  expect(positions[4]).toBeGreaterThan(300);
  expect(positions.at(-1)).toBe(1000);
  expect(rows()[0]!.getAttribute("aria-setsize")).toBe("1000");
});

const TABBABLE = "button:not([disabled]), a[href], input:not([disabled]), [tabindex]:not([tabindex='-1'])";

async function scrollBody(body: HTMLElement, top: number) {
  await act(async () => {
    body.scrollTop = top;
    body.dispatchEvent(new dom.window.Event("scroll"));
    await new Promise((resolve) => setTimeout(resolve, 0));
  });
}

/** One Tab as a browser does it (jsdom moves no focus on Tab): the next tab stop in document order
 *  takes focus, and a row out of view scrolls into view in the body. */
async function tab(body: HTMLElement, shift = false) {
  const document = dom.window.document;
  const stops = [...document.querySelectorAll<HTMLElement>(TABBABLE)];
  const next = stops[stops.indexOf(document.activeElement as HTMLElement) + (shift ? -1 : 1)];
  await act(async () => next?.focus());
  const row = next?.closest<HTMLElement>("[data-index]");
  if (row) {
    const top = Number(row.dataset.index) * ROW;
    if (top < body.scrollTop || top + ROW > body.scrollTop + BODY)
      await scrollBody(body, top < body.scrollTop ? top : top + ROW - BODY);
  }
}

const name = (index: number) => `file-${String(index).padStart(5, "0")}.txt`;
/** The entry whose row holds focus. */
const focusedEntry = () =>
  dom.window.document.activeElement?.closest<HTMLElement>("[data-path]")?.dataset.path?.split("/").pop();
const rowOf = (index: number) => host.querySelector<HTMLElement>(`[data-path="${FOLDER}/${name(index)}"]`);

test("Tab from a focused row the body scrolled 20,000 px away goes to the next entry", async () => {
  const { body } = await mount(1_000);
  await act(async () => rowOf(2)!.querySelector<HTMLElement>(".cloud-file-remove")!.focus());
  await scrollBody(body, 20_000);
  await tab(body);
  expect(focusedEntry()).toBe(name(3));
});

test("Shift-Tab from a focused row the body scrolled 20,000 px away goes to the entry before it", async () => {
  const { body } = await mount(1_000);
  await act(async () => rowOf(5)!.querySelector<HTMLElement>(".cloud-file-name")!.focus());
  await scrollBody(body, 20_000);
  await tab(body, true);
  expect(focusedEntry()).toBe(name(4));
});

test("Shift-Tab into the list from the control after it enters at the last entry", async () => {
  const { body } = await mount(1_000);
  await act(async () => dom.window.document.getElementById("after")!.focus());
  await tab(body, true);
  expect(focusedEntry()).toBe(name(999));
  expect(rowOf(999)).not.toBeNull();
});
