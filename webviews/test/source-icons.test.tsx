// Lucas 2026-10-19: Thread details listed every source with the same globe or search icon. A
// source now shows its site's icon (labs sourceIcons): the one cmux holds, else the site's own,
// fetched once per site by the host; a search aimed at one site (`site:…`) shows that site's.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const keys = ["window", "document", "navigator", "HTMLElement", "customElements", "IS_REACT_ACT_ENVIRONMENT"] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>");
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    customElements: window.customElements,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.querySelector<HTMLElement>("#root")!;
});

afterEach(async () => {
  act(() => root?.unmount());
  root = undefined;
  const { resetLinkStore } = await import("../src/agent-session/acpmux/chips/linkStore");
  const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
  const { configureLabs } = await import("../src/agent-session/acpmux/labs");
  resetLinkStore();
  setChipHost(undefined);
  configureLabs({});
});

afterAll(() => {
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const ICON = "data:image/png;base64,iVBORw0KGgo=";
const SOURCES = [
  { url: "https://www.consumerreports.org/cars/toyota/rav4-hybrid/2021/reliability", label: "consumerreports.org/cars" },
  { url: "https://www.consumerreports.org/cars/honda/cr-v-hybrid/2021/reliability", label: "consumerreports.org/honda" },
  { label: "Search site:trademe.co.nz 2021 Toyota RAV4 hybrid" },
  { label: "Search best hybrid SUV 2021" },
];

async function render(asked: string[]) {
  const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
  setChipHost(async (method, params) => {
    if (method === "link.favicon") {
      asked.push(new URL(String(params.url)).host);
      return { icon: ICON };
    }
    return {};
  });
  const { createRoot } = await import("react-dom/client");
  const { SummaryBody } = await import("../src/agent-session/acpmux/summary/SummaryBody");
  root = createRoot(host);
  const summary = { scheduled: [], pullRequests: [], outputs: [], subagents: [], sources: SOURCES, backgroundTasks: [] };
  await act(async () => root!.render(<SummaryBody summary={summary as never} />));
  for (let tick = 0; tick < 4; tick++) await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  const rows = [...host.querySelectorAll("section")]
    .find((section) => section.querySelector("h3")?.textContent === "Sources")!
    .querySelectorAll("li");
  return [...rows].map((row) => (row.querySelector("img.acpmux-summary-favicon") ? "site" : (row.querySelector("svg")?.getAttribute("data-icon") ?? "")));
}

test("sources show their site's icon, a site: search its site's, a plain search the search icon", async () => {
  const asked: string[] = [];
  expect(await render(asked)).toEqual(["site", "site", "site", "search.files"]);
  // One request per site, however many of its pages are sources.
  expect(asked.sort()).toEqual(["trademe.co.nz", "www.consumerreports.org"]);
});

test("with sourceIcons off nothing is fetched and the generic icons stay", async () => {
  const { configureLabs } = await import("../src/agent-session/acpmux/labs");
  configureLabs({ labs: { sourceIcons: false } });
  const asked: string[] = [];
  expect(await render(asked)).toEqual(["link.web", "link.web", "search.files", "search.files"]);
  expect(asked).toEqual([]);
});

test("a search names its site only through site:", async () => {
  const { searchSite } = await import("../src/agent-session/acpmux/summary/SummaryBody");
  expect(searchSite("Search site:trademe.co.nz 2021 RAV4")).toBe("https://trademe.co.nz/");
  expect(searchSite("Search \"2021\" site:Toyota.co.nz fuel")).toBe("https://toyota.co.nz/");
  expect(searchSite("Search best hybrid SUV")).toBeUndefined();
  expect(searchSite("Search site:localhost")).toBeUndefined();
});
