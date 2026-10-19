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
  {
    url: "https://www.consumerreports.org/cars/toyota/rav4-hybrid/2021/reliability",
    label: "consumerreports.org/cars",
  },
  {
    url: "https://www.consumerreports.org/cars/honda/cr-v-hybrid/2021/reliability",
    label: "consumerreports.org/honda",
  },
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
  const summary = {
    scheduled: [],
    pullRequests: [],
    outputs: [],
    subagents: [],
    sources: SOURCES,
    backgroundTasks: [],
  };
  await act(async () => root!.render(<SummaryBody summary={summary as never} />));
  for (let tick = 0; tick < 4; tick++) await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  const rows = [...host.querySelectorAll("section")]
    .find((section) => section.querySelector("h3")?.textContent === "Sources")!
    .querySelectorAll("li");
  return [...rows].map((row) =>
    row.querySelector("img.acpmux-summary-favicon")
      ? "site"
      : (row.querySelector("svg")?.getAttribute("data-icon") ?? ""),
  );
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
  expect(searchSite('Search "2021" site:Toyota.co.nz fuel')).toBe("https://toyota.co.nz/");
  expect(searchSite("Search best hybrid SUV")).toBeUndefined();
  expect(searchSite("Search site:localhost")).toBeUndefined();
});

async function renderIcons(urls: string[], fetch = true) {
  const { createRoot } = await import("react-dom/client");
  const { useSourceIcon } = await import("../src/agent-session/acpmux/chips/linkStore");
  function Icons() {
    return (
      <>
        {urls.map((url) => (
          <Site key={url} url={url} />
        ))}
      </>
    );
  }
  function Site({ url }: { url: string }) {
    const icon = useSourceIcon(url, fetch);
    return icon ? <img src={icon} alt="" /> : null;
  }
  root ??= createRoot(host);
  await act(async () => root?.render(<Icons />));
}

test("inspection finishes with a held icon before any favicon request", async () => {
  const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
  let inspect: ((value: unknown) => void) | undefined;
  const calls: string[] = [];
  const url = "https://held.example/page";
  setChipHost(async (method) => {
    calls.push(method);
    if (method === "link.inspect")
      return new Promise((resolve) => {
        inspect = resolve;
      });
    return { icon: ICON };
  });
  await renderIcons([url]);
  const beforeInspection = [...calls];
  await act(async () => inspect?.({ sites: { [url]: { icon: ICON } } }));
  expect(beforeInspection).toEqual(["link.inspect"]);
  expect(host.querySelector("img")?.getAttribute("src")).toBe(ICON);
  expect(calls.filter((method) => method === "link.favicon")).toEqual([]);
});

for (const negative of [false, true]) {
  test(`favicon ${negative ? "negative" : "positive"} cache evicts least recently used origins`, async () => {
    const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
    const calls: string[] = [];
    setChipHost(async (method, params) => {
      if (method === "link.favicon") {
        calls.push(String(params.url));
        return negative ? {} : { icon: ICON };
      }
      return {};
    });
    const url = (n: number) => `https://cache${n}.example/page`;
    for (let n = 0; n < 128; n++) await renderIcons([url(n)]);
    await renderIcons([url(0)]);
    await renderIcons([url(128)]);
    await renderIcons([url(0)]);
    expect(calls.filter((value) => value === url(0))).toHaveLength(1);
    await renderIcons([url(1)]);
    expect(calls.filter((value) => value === url(1))).toHaveLength(2);
  });
}

test("invalid sources cannot reserve a valid origin's favicon entry", async () => {
  const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
  const calls: string[] = [];
  setChipHost(async (method, params) => {
    if (method === "link.favicon") {
      const url = String(params.url);
      calls.push(url);
      if (url.includes("@") || new TextEncoder().encode(url).length > 2048 || url.includes("\0")) return {};
      return { icon: ICON };
    }
    return {};
  });
  await renderIcons([
    "https://user:secret@valid.example/page",
    "https://long.example/" + "é".repeat(1100),
    "https://nul.example/\0",
    "https://@empty.example/page",
  ]);
  const valid = [
    "https://valid.example/page",
    "https://long.example/page",
    "https://nul.example/page",
    "https://empty.example/page",
  ];
  await renderIcons(valid);
  expect(calls.sort()).toEqual(valid.sort());
  expect(host.querySelectorAll("img")).toHaveLength(4);
});

test("favicon cache distinguishes schemes and explicit ports", async () => {
  const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
  const calls: string[] = [];
  setChipHost(async (method, params) => {
    if (method === "link.favicon") {
      calls.push(String(params.url));
      return { icon: ICON };
    }
    return {};
  });
  await renderIcons(["http://ports.example/page", "https://ports.example/page", "https://ports.example:8443/page"]);
  expect(calls.sort()).toEqual(["https://ports.example/page", "https://ports.example:8443/page"].sort());
});

test("a native lab refusal is retried after the lab is enabled", async () => {
  const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
  let allowed = false;
  let calls = 0;
  setChipHost(async (method) => {
    if (method === "link.favicon") {
      calls++;
      return allowed ? { icon: ICON } : { disabled: true };
    }
    return {};
  });
  const urls = ["https://lab.example/page"];
  await renderIcons(urls);
  await renderIcons(urls, false);
  allowed = true;
  await renderIcons(urls);
  expect(calls).toBe(2);
  expect(host.querySelector("img")?.getAttribute("src")).toBe(ICON);
});

test("site tokens validate the complete hostname and normalize IDN", async () => {
  const { searchSite } = await import("../src/agent-session/acpmux/summary/SummaryBody");
  const malformed = [
    "example.com_bad",
    "-bad.example",
    "bad-.example",
    "bad..example",
    "example.com/path",
    "example.com:443",
    "a".repeat(64) + ".example",
    "example.com@other.example",
    "example.com%20",
  ];
  for (const token of malformed) expect(searchSite(`Search site:${token} query`)).toBeUndefined();
  expect(searchSite("Search site:foo.comé.example query")).toBe("https://foo.xn--com-dma.example/");
  expect(searchSite("Search site:bücher.example query")).toBe("https://xn--bcher-kva.example/");
  const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
  const calls: string[] = [];
  setChipHost(async (method) => {
    calls.push(method);
    return {};
  });
  await renderIcons(malformed.map((token) => searchSite(`site:${token}`)).filter((url): url is string => !!url));
  expect(calls).toEqual([]);
});

test("the last source reader cancels shared native favicon work", async () => {
  const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
  const { useSourceIcon } = await import("../src/agent-session/acpmux/chips/linkStore");
  const { createRoot } = await import("react-dom/client");
  const calls: string[] = [];
  let finish: ((reply: unknown) => void) | undefined;
  setChipHost(async (method) => {
    calls.push(method);
    if (method === "link.favicon")
      return new Promise((resolve) => {
        finish = resolve;
      });
    return {};
  });
  function Reader({ url }: { url: string }) {
    useSourceIcon(url, true);
    return null;
  }
  const first = "https://shared.example/one";
  const second = "https://shared.example/two";
  root = createRoot(host);
  await act(async () =>
    root?.render(
      <>
        <Reader key="one" url={first} />
        <Reader key="two" url={second} />
      </>,
    ),
  );
  await act(async () => root?.render(<Reader key="two" url={second} />));
  expect(calls.filter((method) => method === "link.cancelFavicon")).toHaveLength(0);
  await act(async () => root?.unmount());
  root = undefined;
  await act(async () => finish?.({}));
  expect(calls.filter((method) => method === "link.favicon")).toHaveLength(1);
  expect(calls.filter((method) => method === "link.cancelFavicon")).toHaveLength(1);
});
