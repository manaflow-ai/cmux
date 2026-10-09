import { afterAll, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
const dom = new JSDOM("<!doctype html><div id=root></div>", { url: "https://pane.test/", pretendToBeVisual: true, virtualConsole: new VirtualConsole() });
const globals = globalThis as Record<string, unknown>;
const names = ["window", "document", "navigator", "Node", "Element", "HTMLElement", "customElements", "MutationObserver", "getComputedStyle", "requestAnimationFrame", "cancelAnimationFrame", "ResizeObserver", "IS_REACT_ACT_ENVIRONMENT"];
const saved = Object.fromEntries(names.map(key => [key, globals[key]]));
for (const name of names) globals[name] = (dom.window as unknown as Record<string, unknown>)[name];
globals.getComputedStyle = dom.window.getComputedStyle.bind(dom.window);
globals.IS_REACT_ACT_ENVIRONMENT = true;
let width = 1200;
let resize: (() => void) | undefined;
globals.ResizeObserver = class {
  constructor(callback: (entries: unknown[]) => void) { resize = () => callback([{ contentRect: { width } }]); }
  observe() { resize?.(); }
  disconnect() {}
};
afterAll(() => Object.assign(globals, saved));
const { act, createElement: h } = await import("react");
const { createRoot } = await import("react-dom/client");
const { SummaryButton } = await import("./SummaryButton");
const { UiProvider } = await import("../../../ui/UiProvider");
async function mount(rows: Record<string, unknown>[] = [], provenance = "agent") {
  const root = createRoot(document.getElementById("root")!);
  const props = { rows: [], cwd: "/repo", sections: [{ id: "custom", title: "Custom", rows: rows.map(row => ({ provenance, ...row })) }] };
  await act(async () => root.render(h(UiProvider as any, { container: document.body, dir: "ltr" },
    h("div", { className: "acpmux-stage" }, h("header", null, h(SummaryButton, props as any)), h("div", { className: "acpmux-summary-slot" }), h("div", { className: "acpmux-scroll" }, "Transcript")))));
  return { button: document.querySelector<HTMLButtonElement>(".acpmux-summary-button")!, unmount: () => act(async () => root.unmount()) };
}
const click = (node: Element | null | undefined) => act(async () => (node as HTMLElement)?.click());
const card = () => document.querySelector("[data-summary-mode]");
const reset = () => { width = 1200; dom.window.localStorage.clear(); };
test("pin is on in wide panes and persists across remounts", async () => {
  reset(); let view = await mount();
  try {
    expect(card()?.getAttribute("data-summary-mode")).toBe("pinned");
    await click(view.button); expect(card()).toBeNull();
    expect(dom.window.localStorage.getItem("agentPane.summary.pinned")).toBe("false");
    await view.unmount(); view = await mount(); expect(card()).toBeNull();
    await click(view.button); expect(card()?.getAttribute("data-summary-mode")).toBe("pinned");
  } finally { await view.unmount(); }
});
test("narrow fallback reserves a slot and preserves the pin preference", async () => {
  reset(); const view = await mount();
  try {
    await act(async () => { width = 560; resize?.(); }); expect(card()).toBeNull();
    await click(view.button); expect(card()?.getAttribute("data-summary-mode")).toBe("popover");
    expect(card()?.parentElement?.className).toBe("acpmux-summary-slot");
    await act(async () => card()?.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "Escape", bubbles: true })));
    expect(card()).toBeNull(); expect(document.activeElement).toBe(view.button);
    await act(async () => { width = 1200; resize?.(); }); expect(card()?.getAttribute("data-summary-mode")).toBe("pinned");
  } finally { await view.unmount(); }
});
test("rows are text only and href allowlist drops javascript, data and escaping paths", async () => {
  reset(); const view = await mount([
    { title: '<img src=x onerror="alert(1)">', subtitle: "**not markdown**", icon: "https://evil.test/image", href: "javascript:alert(1)" },
    { title: "Data", href: "data:text/html,<script>bad()</script>" }, { title: "Outside", href: "/repo-other/private" }, { title: "Traversal", href: "/repo/%2e%2e/private" },
  ]);
  try {
    expect(card()?.textContent).toContain('<img src=x onerror="alert(1)">');
    expect(card()?.querySelector("img, script, iframe")).toBeNull(); expect(card()?.querySelector("[href]")).toBeNull();
  } finally { await view.unmount(); }
});
test("agent href needs inline confirmation, in-folder paths do not", async () => {
  reset(); const view = await mount([{ title: "Website", href: "https://example.com/docs" }, { title: "Local", href: "/repo/notes.md" }]);
  try {
    expect(card()?.querySelector('a[href="https://example.com/docs"]')).toBeNull();
    await click([...card()!.querySelectorAll("button")].find(node => node.textContent?.includes("Website")));
    expect(card()?.textContent).toContain("Open agent link?");
    expect(card()?.querySelector('a[href="https://example.com/docs"]')?.textContent).toContain("Open link");
    expect(card()?.querySelector('[data-summary-path="/repo/notes.md"]')).not.toBeNull();
  } finally { await view.unmount(); }
});
test("a section caps at 50 rows even after View all", async () => {
  reset(); const view = await mount(Array.from({ length: 80 }, (_, index) => ({ title: `Item ${index}` })), "user");
  try {
    await click([...card()!.querySelectorAll("button")].find(node => node.textContent?.includes("View all 50")));
    expect(card()?.querySelectorAll('[data-section-id="custom"] [data-provenance]')).toHaveLength(50);
    expect(card()?.textContent).not.toContain("Item 50");
  } finally { await view.unmount(); }
});
