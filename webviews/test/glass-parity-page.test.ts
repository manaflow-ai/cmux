// The Liquid Glass Parity page (pages/glass-parity/main.tsx): each surface is the web UI's own class for
// its kind at the box the App sends, marked for the App's glass only in host mode, and the host mode asks
// for the App's glass in either engine.
import { afterEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";

let dom: JSDOM | undefined;
afterEach(() => {
  dom?.window.close();
  dom = undefined;
});

async function load() {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { pretendToBeVisual: true });
  const window = dom.window as unknown as Window & typeof globalThis;
  for (const key of ["document", "window", "HTMLElement", "Element", "Node", "MutationObserver", "getComputedStyle"])
    (globalThis as Record<string, unknown>)[key] = (window as unknown as Record<string, unknown>)[key];
  return import("../src/pages/glass-parity/main");
}

test("a cell is the web UI's surface for its kind, at its box, marked for host glass only in host mode", async () => {
  const { PARITY_CLASS, PARITY_FIXTURE, PARITY_LEVEL, paritySurface } = await load();
  const doc = dom!.window.document;
  for (const cell of PARITY_FIXTURE.cells) {
    const host = paritySurface(doc, cell, "host");
    for (const name of PARITY_CLASS[cell.kind].split(" ")) expect(host.classList.contains(name)).toBe(true);
    expect(host.getAttribute("data-host-glass")).toBe(PARITY_LEVEL[cell.kind]);
    expect(host.style.left).toBe(`${cell.left}px`);
    expect(host.style.top).toBe(`${cell.top}px`);
    expect(host.style.width).toBe(`${cell.width}px`);
    expect(host.style.borderRadius).toBe(`${cell.radius}px`);
    expect(host.textContent).toBe(`${cell.title}${cell.detail}`);
    const css = paritySurface(doc, cell, "css");
    expect(css.hasAttribute("data-host-glass")).toBe(false);
  }
});

test("host mode asks for the App's glass in either engine and reports through the page's op", async () => {
  const { GlassParityOps, PARITY_FIXTURE, renderParity } = await load();
  const doc = dom!.window.document;
  const root = doc.getElementById("root")!;
  const calls: string[] = [];
  const client = { call: (op: string) => (calls.push(op), Promise.resolve({})) } as never;
  const stop = renderParity(doc, root, { ...PARITY_FIXTURE, mode: "host" }, client);
  expect(root.childElementCount).toBe(PARITY_FIXTURE.cells.length);
  expect(doc.documentElement.getAttribute("data-host-glass-engines")).toBe("all");
  stop();
  expect(calls.every((op) => op === GlassParityOps.surfaces)).toBe(true);
  const plain = renderParity(doc, root, PARITY_FIXTURE, client);
  expect(root.querySelectorAll("[data-host-glass]").length).toBe(0);
  plain();
});
