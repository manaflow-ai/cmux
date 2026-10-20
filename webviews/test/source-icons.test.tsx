// Lucas 2026-10-19: Thread details listed every source with the same globe or search icon. A
// source now shows its site's icon (labs sourceIcons): the one cmux holds, else the site's own,
// fetched once per site by the host; a search aimed at one site (`site:…`) shows that site's.
import { afterAll, afterEach, beforeAll, expect, spyOn, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";
import { build } from "esbuild";
import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import { act, type ReactNode } from "react";
import type { Root } from "react-dom/client";
import { reactCompilerPlugin } from "../scripts/agent-pane/reactCompilerPlugin.mjs";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "HTMLElement",
  "Element",
  "Node",
  "MutationObserver",
  "customElements",
  "ResizeObserver",
  "IntersectionObserver",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "IS_REACT_ACT_ENVIRONMENT",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  const { window } = new JSDOM("<!doctype html><div id=root></div>", {
    pretendToBeVisual: true,
    virtualConsole: new VirtualConsole(),
  });
  Object.assign(scope, {
    window,
    document: window.document,
    navigator: window.navigator,
    HTMLElement: window.HTMLElement,
    Element: window.Element,
    Node: window.Node,
    MutationObserver: window.MutationObserver,
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    IntersectionObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    requestAnimationFrame: window.requestAnimationFrame.bind(window),
    cancelAnimationFrame: window.cancelAnimationFrame.bind(window),
    customElements: window.customElements,
    IS_REACT_ACT_ENVIRONMENT: true,
  });
  host = window.document.querySelector<HTMLElement>("#root")!;
  Object.defineProperty(window.HTMLElement.prototype, "clientHeight", {
    configurable: true,
    get: () => 10_000,
  });
  Object.defineProperty(window.HTMLElement.prototype, "clientWidth", {
    configurable: true,
    get: () => 760,
  });
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

test("Thread details waits for settled fetch-tool metadata before requesting an icon", async () => {
  const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
  const { sessionSummary } = await import("../src/agent-session/acpmux/summary/sessionSummary");
  const { SummaryBody } = await import("../src/agent-session/acpmux/summary/SummaryBody");
  const { createRoot } = await import("react-dom/client");
  const calls: string[] = [];
  setChipHost(async (method, params) => {
    if (method === "link.favicon") calls.push(String(params.url));
    return {};
  });
  root = createRoot(host);
  const draw = async (title: string, status: string) => {
    const summary = sessionSummary([
      {
        id: "tools",
        kind: "activity",
        items: [{ id: "fetch", tool: { id: "fetch", kind: "fetch", title, status } }],
      },
    ] as never);
    await act(async () => root?.render(<SummaryBody summary={summary} />));
  };
  await draw("Fetch https://example.com", "pending");
  await draw("Fetch https://example.com.evil.net/finished", "in_progress");
  expect(calls).toEqual([]);
  await draw("Fetch https://example.com.evil.net/finished", "completed");
  expect(calls).toEqual(["https://example.com.evil.net/finished"]);
});

test("streaming reply links wait for transport completion and fully revealed text", async () => {
  const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
  const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");
  const { createRoot } = await import("react-dom/client");
  const calls: string[] = [];
  setChipHost(async (method, params) => {
    if (method === "link.favicon") calls.push(String(params.url));
    return {};
  });
  root = createRoot(host);
  const draw = async (text: string, streaming: boolean) => {
    await act(async () =>
      root?.render(
        <VirtualTranscript
          rows={[{ id: "reply", kind: "assistant", text, streaming, at: 1, version: text.length }]}
          expanded={new Set()}
          onToggleActivity={() => {}}
        />,
      ),
    );
  };
  await draw("https://example.com", true);
  expect(calls).toEqual([]);
  // Mount finished history, whose reveal is already complete.
  act(() => root?.unmount());
  root = createRoot(host);
  await draw("https://example.com.evil.net/finished", false);
  expect(calls).toEqual(["https://example.com.evil.net/finished"]);
});

test("a finished row waits for reveal catch-up before requesting the final hostname", async () => {
  const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
  const { RevealedMarkdown, revealFrames } = await import("../src/agent-session/acpmux/conversation/RevealedMarkdown");
  const { ReplySourceIconsContext } = await import("../src/agent-session/acpmux/chips/ReplySourceIconsContext");
  const { createRoot } = await import("react-dom/client");
  const { configureLabs } = await import("../src/agent-session/acpmux/labs");
  configureLabs({ labs: { liveRender: false } });
  const frames = new Map<number, (now: number) => void>();
  let frameID = 0;
  const request = spyOn(revealFrames, "request").mockImplementation((callback) => {
    frames.set(++frameID, callback);
    return frameID;
  });
  const cancel = spyOn(revealFrames, "cancel").mockImplementation((id) => {
    frames.delete(id);
  });
  try {
    const calls: string[] = [];
    setChipHost(async (method, params) => {
      if (method === "link.favicon") calls.push(String(params.url));
      return { icon: ICON };
    });
    root = createRoot(host);
    const draw = async (text: string, streaming: boolean) => {
      await act(async () =>
        root?.render(
          <ReplySourceIconsContext.Provider value={true}>
            <RevealedMarkdown text={text} streaming={streaming} />
          </ReplySourceIconsContext.Provider>,
        ),
      );
    };
    await draw("https://example.com", true);
    await draw("https://example.com.evil.net/finished", true);
    await draw("https://example.com.evil.net/finished", false);
    expect(calls).toEqual([]);
    // Display-frame time is explicit; there is no wall-clock wait.
    for (const now of [0, 100, 200, 300]) {
      await act(async () => {
        const due = [...frames.values()];
        frames.clear();
        for (const tick of due) tick(now);
      });
    }
    expect(calls.map((url) => new URL(url).origin)).toEqual(["https://example.com.evil.net"]);
    expect(host.querySelector("img.cv-chip__favicon")?.getAttribute("src")).toBe(ICON);
  } finally {
    act(() => root?.unmount());
    root = undefined;
    request.mockRestore();
    cancel.mockRestore();
  }
});

test("a path change keeps the origin's pending request and cancels only on unmount", async () => {
  const { useSourceIcon } = await import("../src/agent-session/acpmux/chips/linkStore");
  const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
  const { createRoot } = await import("react-dom/client");
  const calls: string[] = [];
  let finish: ((value: unknown) => void) | undefined;
  setChipHost(async (method) => {
    calls.push(method);
    return method === "link.favicon"
      ? new Promise((resolve) => {
          finish = resolve;
        })
      : {};
  });
  function Reader({ url }: { url: string }) {
    useSourceIcon(url, true, "chat");
    return null;
  }
  root = createRoot(host);
  await act(async () => root?.render(<Reader url="https://path.example/a" />));
  await act(async () => root?.render(<Reader url="https://path.example/ab" />));
  expect(calls.filter((method) => method === "link.favicon")).toHaveLength(1);
  expect(calls.filter((method) => method === "link.cancelFavicon")).toHaveLength(0);
  await act(async () => root?.unmount());
  root = undefined;
  await act(async () => finish?.({ temporary: true }));
  expect(calls.filter((method) => method === "link.cancelFavicon")).toHaveLength(1);
});

test("mounted temporary readers share one cancellable retry without restoring budget", async () => {
  const { useSourceIcon } = await import("../src/agent-session/acpmux/chips/linkStore");
  const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
  const { createRoot } = await import("react-dom/client");
  let now = 1000;
  const timers = new Map<number, { at: number; fire: () => void }>();
  let timerID = 0;
  const realTimer = globalThis.setTimeout;
  const realClear = globalThis.clearTimeout;
  const date = spyOn(Date, "now").mockImplementation(() => now);
  const timeout = spyOn(globalThis, "setTimeout").mockImplementation(((fire: () => void, delay: number) => {
    if (delay < 1000) return realTimer(fire, delay);
    const id = ++timerID;
    timers.set(id, { at: now + delay, fire });
    return id;
  }) as typeof setTimeout);
  const clear = spyOn(globalThis, "clearTimeout").mockImplementation(((id: number) => {
    if (!timers.delete(id)) realClear(id);
  }) as typeof clearTimeout);
  try {
    const calls: string[] = [];
    setChipHost(async (method, params) => {
      if (method === "link.favicon") {
        calls.push(String(params.url));
        return { temporary: true };
      }
      return {};
    });
    function Reader({ url }: { url: string }) {
      useSourceIcon(url, true, "chat");
      return null;
    }
    const urls = Array.from({ length: 32 }, (_, n) => `https://retry${n}.example/one`);
    root = createRoot(host);
    await act(async () =>
      root?.render(
        <>
          {urls.map((url) => (
            <Reader key={url} url={url} />
          ))}
          <Reader url={urls[0]!} />
        </>,
      ),
    );
    expect(calls).toHaveLength(32);
    expect(timers.size).toBe(32);
    await act(async () => {
      now += 31_000;
      const due = [...timers.values()];
      timers.clear();
      for (const timer of due) {
        expect(timer.at).toBeLessThanOrEqual(now);
        timer.fire();
      }
    });
    expect(calls).toHaveLength(64);
    expect(timers.size).toBe(0);
    await act(async () => root?.render(<Reader url="https://over-budget.example/" />));
    expect(calls).toHaveLength(64);
    expect(timers.size).toBe(0);
  } finally {
    timeout.mockRestore();
    clear.mockRestore();
    date.mockRestore();
  }
});

for (const reply of [{}, undefined]) {
  test(`${reply ? "a genuine miss" : "an unmarked host failure"} is never requested again while mounted, even after negative expiry`, async () => {
    const { useSourceIcon } = await import("../src/agent-session/acpmux/chips/linkStore");
    const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
    const { createRoot } = await import("react-dom/client");
    let now = 1000;
    const timers: (() => void)[] = [];
    const realTimer = globalThis.setTimeout;
    const date = spyOn(Date, "now").mockImplementation(() => now);
    const timeout = spyOn(globalThis, "setTimeout").mockImplementation(((fire: () => void, delay: number) => {
      if (delay < 1000) return realTimer(fire, delay);
      timers.push(fire);
      return 98765;
    }) as typeof setTimeout);
    try {
      let calls = 0;
      setChipHost(async (method) => {
        if (method === "link.favicon") calls++;
        return reply;
      });
      function Reader() {
        useSourceIcon("https://genuine-miss.example/", true);
        return null;
      }
      root = createRoot(host);
      await act(async () => root?.render(<Reader />));
      expect(calls).toBe(1);
      // Fire any queued timer explicitly so a scheduled retry cannot hide behind virtual time.
      await act(async () => {
        now += 11 * 60_000;
        for (const fire of timers) fire();
        root?.render(<Reader />);
      });
      expect(calls).toBe(1);
      expect(timers).toHaveLength(0);
    } finally {
      timeout.mockRestore();
      date.mockRestore();
    }
  });
}

test("a genuine miss survives remounts for ten minutes in the same document", async () => {
  const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
  let now = 1000;
  const date = spyOn(Date, "now").mockImplementation(() => now);
  try {
    let calls = 0;
    setChipHost(async (method) => {
      if (method === "link.favicon") calls++;
      return {};
    });
    await renderIcons(["https://cached-miss.example/one"]);
    expect(calls).toBe(1);
    now += 31_000;
    await renderIcons(["https://cached-miss.example/two"]);
    expect(calls).toBe(1);
    now = 1000 + 10 * 60_000 - 1;
    await renderIcons(["https://cached-miss.example/three"]);
    expect(calls).toBe(1);
    now++;
    await renderIcons(["https://cached-miss.example/four"]);
    expect(calls).toBe(2);
  } finally {
    date.mockRestore();
  }
});

test("unmount cancels a scheduled retry and stale replies cannot restart it", async () => {
  const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
  const date = spyOn(Date, "now").mockReturnValue(1000);
  const realTimer = globalThis.setTimeout;
  const realClear = globalThis.clearTimeout;
  let fire: (() => void) | undefined;
  let cancelled = false;
  let calls = 0;
  const timeout = spyOn(globalThis, "setTimeout").mockImplementation(((callback: () => void, delay: number) => {
    if (delay < 1000) return realTimer(callback, delay);
    fire = callback;
    return 98765;
  }) as typeof setTimeout);
  const clear = spyOn(globalThis, "clearTimeout").mockImplementation(((id: number) => {
    if (id === 98765) cancelled = true;
    else realClear(id);
  }) as typeof clearTimeout);
  try {
    setChipHost(async (method) => {
      if (method === "link.favicon") {
        calls++;
        return { temporary: true };
      }
      return {};
    });
    await renderIcons(["https://cancel-retry.example/"]);
    expect(fire).toBeDefined();
    await act(async () => root?.unmount());
    root = undefined;
    expect(cancelled).toBe(true);
    await act(async () => fire?.());
    expect(calls).toBe(1);
  } finally {
    timeout.mockRestore();
    clear.mockRestore();
    date.mockRestore();
  }
});
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

test("a held icon is reused by origin during another path's inspection and after its empty answer", async () => {
  const { seedLinkStore } = await import("../src/agent-session/acpmux/chips/linkStore");
  const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
  seedLinkStore({ sites: { "https://held.example/one": { icon: ICON } } });
  let finish: ((value: unknown) => void) | undefined;
  const calls: string[] = [];
  setChipHost(async (method) => {
    calls.push(method);
    if (method === "link.inspect") return new Promise((resolve) => { finish = resolve; });
    return {};
  });
  await renderIcons(["https://held.example/two"]);
  expect(host.querySelector("img")?.getAttribute("src")).toBe(ICON);
  expect(calls).toEqual(["link.inspect"]);
  await act(async () => finish?.({ sites: {} }));
  expect(host.querySelector("img")?.getAttribute("src")).toBe(ICON);
  expect(calls).toEqual(["link.inspect"]);
});

test("an earlier empty inspection cannot start a fetch while the current URL is pending", async () => {
  const { seedLinkStore } = await import("../src/agent-session/acpmux/chips/linkStore");
  const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
  seedLinkStore({ sites: { "https://pending.example/one": {} } });
  const url = "https://pending.example/two";
  let finish: ((value: unknown) => void) | undefined;
  const calls: string[] = [];
  setChipHost(async (method) => {
    calls.push(method);
    if (method === "link.inspect") return new Promise((resolve) => { finish = resolve; });
    return { icon: ICON };
  });
  await renderIcons([url]);
  expect(calls).toEqual(["link.inspect"]);
  await act(async () => finish?.({ sites: { [url]: { icon: ICON } } }));
  expect(host.querySelector("img")?.getAttribute("src")).toBe(ICON);
  expect(calls).toEqual(["link.inspect"]);
});

test("changing a reader's path during inspection never restarts its existing origin request", async () => {
  const { useSourceIcon } = await import("../src/agent-session/acpmux/chips/linkStore");
  const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
  const { createRoot } = await import("react-dom/client");
  let inspect: ((value: unknown) => void) | undefined;
  let icon: ((value: unknown) => void) | undefined;
  const calls: string[] = [];
  setChipHost(async (method) => {
    calls.push(method);
    if (method === "link.inspect") return new Promise((resolve) => { inspect = resolve; });
    if (method === "link.favicon") return new Promise((resolve) => { icon = resolve; });
    return {};
  });
  function Reader({ url }: { url: string }) {
    const src = useSourceIcon(url, true);
    return src ? <img src={src} alt="" /> : null;
  }
  root = createRoot(host);
  await act(async () => root?.render(<Reader url="https://reader.example/one" />));
  await act(async () => inspect?.({ sites: {} }));
  await act(async () => root?.render(<Reader url="https://reader.example/two" />));
  expect(calls).toEqual(["link.inspect", "link.favicon", "link.inspect"]);
  await act(async () => inspect?.({ sites: {} }));
  expect(calls).toEqual(["link.inspect", "link.favicon", "link.inspect"]);
  await act(async () => icon?.({ icon: ICON }));
  expect(host.querySelector("img")?.getAttribute("src")).toBe(ICON);
});

for (const negative of [false, true]) {
  test(`favicon ${negative ? "negative" : "positive"} results share a 64-origin lifetime budget with chat`, async () => {
    const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
    const calls: string[] = [];
    setChipHost(async (method, params) => {
      if (method === "link.favicon") {
        calls.push(String(params.url));
        return negative ? {} : { icon: ICON };
      }
      return {};
    });
    const source = (n: number) => `https://source${n}.example/page`;
    const replies = Array.from({ length: 32 }, (_, n) => `https://reply${n}.example/page`);
    const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");
    const { createRoot } = await import("react-dom/client");
    root = createRoot(host);
    await act(async () =>
      root!.render(
        <VirtualTranscript
          rows={[{ id: "message", kind: "assistant", text: replies.join("\n\n"), at: 1, version: 1 }]}
          expanded={new Set()}
          onToggleActivity={() => {}}
        />,
      ),
    );
    expect(calls).toEqual(replies);
    for (let n = 0; n < 32; n++) await renderIcons([source(n)]);
    await renderIcons([source(0), source(32)]);
    expect(calls).toEqual([...replies, ...Array.from({ length: 32 }, (_, n) => source(n))]);
    expect(calls.filter((value) => value === source(0))).toHaveLength(1);
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

test("compiled sources and opted-in UrlChips fetch after inspection and display completed icons", async () => {
  const out = mkdtempSync(path.join(tmpdir(), "source-icons-compiled-"));
  let compiledRoot: Root | undefined;
  let finishIcon: ((reply: unknown) => void) | undefined;
  try {
    const webviews = path.resolve(import.meta.dir, "..");
    const compiled = new Set<string>();
    await build({
      stdin: {
        contents: [
          'export { ReplySourceIconsContext } from "./src/agent-session/acpmux/chips/ReplySourceIconsContext";',
          'export { UrlChip } from "./src/agent-session/acpmux/chips/LinkChips";',
          'export { SummaryBody } from "./src/agent-session/acpmux/summary/SummaryBody";',
          'export { setChipHost } from "./src/agent-session/acpmux/chips/host";',
          'export { createRoot } from "react-dom/client";',
          'export { act } from "react";',
        ].join("\n"),
        resolveDir: webviews,
        loader: "ts",
      },
      bundle: true,
      format: "esm",
      platform: "browser",
      define: { "process.env.NODE_ENV": '"development"' },
      outfile: path.join(out, "sources.js"),
      logLevel: "silent",
      plugins: [
        reactCompilerPlugin({
          mode: "babel",
          srcRoot: path.join(webviews, "src"),
          onCompiled: (id: string) => compiled.add(id),
        }),
      ],
    });
    expect(compiled.has("agent-session/acpmux/chips/linkStore.ts:useSourceIcon")).toBe(true);
    const page = await import(path.join(out, "sources.js"));
    let finishInspect: ((reply: unknown) => void) | undefined;
    const calls: { method: string; params: Record<string, unknown> }[] = [];
    page.setChipHost((method: string, params: Record<string, unknown>) => {
      calls.push({ method, params });
      if (method === "link.inspect")
        return new Promise((resolve) => {
          finishInspect = resolve;
        });
      if (method === "link.favicon")
        return new Promise((resolve) => {
          finishIcon = resolve;
        });
      return Promise.resolve({});
    });
    const passive = "https://compiled-passive.example/read";
    compiledRoot = page.createRoot(host);
    await page.act(async () => compiledRoot?.render(<page.UrlChip href={passive}>Passive</page.UrlChip>));
    await page.act(async () => finishInspect?.({ sites: {} }));
    expect(calls.filter(({ method }) => method === "link.favicon")).toEqual([]);
    await page.act(async () => compiledRoot?.unmount());
    compiledRoot = undefined;
    calls.length = 0;
    const url = "https://en.wikipedia.org/wiki/Albert_Einstein";
    const summary = {
      scheduled: [],
      pullRequests: [],
      outputs: [],
      subagents: [],
      sources: [{ url, label: "Wikipedia" }],
      backgroundTasks: [],
    };
    compiledRoot = page.createRoot(host);
    await page.act(async () => compiledRoot?.render(<page.SummaryBody summary={summary} />));
    expect(calls.map(({ method }) => method)).toEqual(["link.inspect"]);
    expect(host.querySelector("img.acpmux-summary-favicon")).toBeNull();
    await page.act(async () => finishInspect?.({ sites: {} }));
    expect(calls.filter(({ method }) => method === "link.favicon")).toEqual([
      { method: "link.favicon", params: { url } },
    ]);
    // An unrelated render while the host is fetching must not release its reader.
    await page.act(async () => compiledRoot?.render(<page.SummaryBody summary={{ ...summary }} />));
    expect(calls.filter(({ method }) => method === "link.cancelFavicon")).toHaveLength(0);
    await page.act(async () => finishIcon?.({ icon: ICON }));
    expect(host.querySelector("img.acpmux-summary-favicon")?.getAttribute("src")).toBe(ICON);
    expect(calls.filter(({ method }) => method === "link.favicon")).toHaveLength(1);

    calls.length = 0;
    const chipURL = "https://compiled-reply.example/read";
    const reply = () => (
      <page.ReplySourceIconsContext.Provider value={true}>
        <page.UrlChip href={chipURL}>Reply</page.UrlChip>
      </page.ReplySourceIconsContext.Provider>
    );
    await page.act(async () => compiledRoot?.render(reply()));
    expect(calls.map(({ method }) => method)).toEqual(["link.inspect"]);
    expect(host.querySelector("img.cv-chip__favicon")).toBeNull();
    await page.act(async () => finishInspect?.({ sites: {} }));
    expect(calls.filter(({ method }) => method === "link.favicon")).toEqual([
      { method: "link.favicon", params: { url: chipURL } },
    ]);
    await page.act(async () => compiledRoot?.render(reply()));
    expect(calls.filter(({ method }) => method === "link.cancelFavicon")).toHaveLength(0);
    await page.act(async () => finishIcon?.({ icon: ICON }));
    expect(host.querySelector("img.cv-chip__favicon")?.getAttribute("src")).toBe(ICON);
    expect(calls.filter(({ method }) => method === "link.favicon")).toHaveLength(1);

    // A timer-driven retry must also invalidate the compiled hook's store snapshot.
    const date = spyOn(Date, "now").mockReturnValue(1000);
    const realTimer = globalThis.setTimeout;
    let retry: (() => void) | undefined;
    let attempts = 0;
    const timeout = spyOn(globalThis, "setTimeout").mockImplementation(((fire: () => void, delay: number) => {
      if (delay < 1000) return realTimer(fire, delay);
      retry = fire;
      return 98765;
    }) as typeof setTimeout);
    try {
      page.setChipHost(async (method: string) => {
        if (method === "link.favicon") return ++attempts === 1 ? { temporary: true } : { icon: ICON };
        return {};
      });
      await page.act(async () =>
        compiledRoot?.render(
          <page.ReplySourceIconsContext.Provider value={true}>
            <page.UrlChip href="https://compiled-retry.example/">Retry</page.UrlChip>
          </page.ReplySourceIconsContext.Provider>,
        ),
      );
      expect(host.querySelector("img.cv-chip__favicon")).toBeNull();
      expect(retry).toBeDefined();
      await page.act(async () => retry?.());
      expect(attempts).toBe(2);
      expect(host.querySelector("img.cv-chip__favicon")?.getAttribute("src")).toBe(ICON);
    } finally {
      timeout.mockRestore();
      date.mockRestore();
    }
  } finally {
    // Use this bundle's React instance for its root, including on a failing assertion.
    const page = compiledRoot ? await import(path.join(out, "sources.js")) : undefined;
    await page?.act(async () => {
      compiledRoot?.unmount();
      finishIcon?.({});
    });
    rmSync(out, { recursive: true, force: true });
  }
});

// Lucas 2026-10-20: the links in a reply (the chat's own Sources list) kept the globe while Thread
// details showed each site's icon. A web chip fetches the same way, unless it has its own mark.
async function renderChips(asked: string[], chips: { href: string; own?: boolean }[]) {
  const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
  setChipHost(async (method, params) => {
    if (method === "link.favicon") {
      asked.push(new URL(String(params.url)).host);
      return { icon: ICON };
    }
    return {};
  });
  const { createRoot } = await import("react-dom/client");
  const { UrlChip } = await import("../src/agent-session/acpmux/chips/LinkChips");
  const { ReplySourceIconsContext } = await import("../src/agent-session/acpmux/chips/ReplySourceIconsContext");
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <ReplySourceIconsContext.Provider value={true}>
        <ul>
          {chips.map(({ href, own }) => (
            <li key={href}>
              <UrlChip href={href} {...(own ? { icon: <svg data-icon="own" /> } : {})}>
                {href}
              </UrlChip>
            </li>
          ))}
        </ul>
      </ReplySourceIconsContext.Provider>,
    ),
  );
  for (let tick = 0; tick < 4; tick++) await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
  return [...host.querySelectorAll("li")].map((row) =>
    row.querySelector("img.cv-chip__favicon") ? "site" : row.querySelector("svg[data-icon='own']") ? "own" : "globe",
  );
}

test("a reply's web links show their site's icon, once per site, and a chip's own mark wins", async () => {
  const asked: string[] = [];
  expect(
    await renderChips(asked, [
      { href: "https://en.wikipedia.org/wiki/Albert_Einstein" },
      { href: "https://en.wikipedia.org/wiki/Outline_of_Albert_Einstein" },
      { href: "https://github.com/manaflow-ai/cmux", own: true },
    ]),
  ).toEqual(["site", "site", "own"]);
  expect(asked).toEqual(["en.wikipedia.org"]);
});

test("with sourceIcons off a reply's web links fetch nothing and keep the globe", async () => {
  const { configureLabs } = await import("../src/agent-session/acpmux/labs");
  configureLabs({ labs: { sourceIcons: false } });
  const asked: string[] = [];
  expect(await renderChips(asked, [{ href: "https://en.wikipedia.org/wiki/Albert_Einstein" }])).toEqual(["globe"]);
  expect(asked).toEqual([]);
});

// Passive requests disclose the pane's IP even when third-party text is never clicked.
async function renderContent(asked: string[], content: ReactNode) {
  const { setChipHost } = await import("../src/agent-session/acpmux/chips/host");
  const { createRoot } = await import("react-dom/client");
  setChipHost(async (method, params) => {
    if (method === "link.favicon") {
      asked.push(String(params.url));
      return { icon: ICON };
    }
    return {};
  });
  root ??= createRoot(host);
  await act(async () => root!.render(content));
  for (let tick = 0; tick < 4; tick++) await act(async () => new Promise((resolve) => setTimeout(resolve, 0)));
}

async function transcript(text: string, kind = "assistant") {
  const { VirtualTranscript } = await import("../src/agent-session/acpmux/App");
  return (
    <VirtualTranscript
      rows={[{ id: "message", kind, text, at: 1, version: 1 }]}
      expanded={new Set()}
      onToggleActivity={() => {}}
    />
  );
}

for (const body of ["[review](https://review.example/read)", "https://review.example/bare"]) {
  test(`review plainCode Markdown never fetches icons: ${body}`, async () => {
    const { ReviewThread } = await import("../src/agent-session/acpmux/changes/ReviewThread");
    const asked: string[] = [];
    await renderContent(
      asked,
      <ReviewThread
        thread={{
          path: "file.ts",
          side: "additions",
          resolved: false,
          outdated: false,
          moved: false,
          comments: [{ author: "reviewer", body }],
        }}
      />,
    );
    expect(host.querySelectorAll("a.cv-chip")).toHaveLength(1);
    expect(asked).toEqual([]);
  });
}

test("plain Markdown outside a reply never fetches icons for links or bare URLs", async () => {
  const { Markdown } = await import("../src/agent-session/acpmux/conversation/Markdown");
  const asked: string[] = [];
  await renderContent(asked, <Markdown>{"[link](https://plain.example/read) https://bare.example/read"}</Markdown>);
  expect(host.querySelectorAll("a.cv-chip")).toHaveLength(2);
  expect(asked).toEqual([]);
});

test("the transcript's agent reply fetches icons for prose links and bare URLs", async () => {
  const asked: string[] = [];
  await renderContent(asked, await transcript("[link](https://reply.example/read) https://bare.example/read"));
  expect(asked.sort()).toEqual(["https://bare.example/read", "https://reply.example/read"]);
  expect(host.querySelectorAll("img.cv-chip__favicon")).toHaveLength(2);
});

test("quoted tool output inside an agent reply never fetches icons", async () => {
  const asked: string[] = [];
  await renderContent(
    asked,
    await transcript(
      "[prose](https://prose.example/read)\n\n> [tool](https://tool.example/read)\n>\n> > https://nested.example/read",
    ),
  );
  expect(host.querySelectorAll("blockquote a.cv-chip")).toHaveLength(2);
  expect(asked).toEqual(["https://prose.example/read"]);
});

test("user prompts never fetch icons", async () => {
  const asked: string[] = [];
  await renderContent(asked, await transcript("[link](https://user.example/read) https://bare.example/read", "user"));
  expect(asked).toEqual([]);
});

test("chat fetches at most 32 distinct origins for the page lifetime, resetLinkStore restores the budget", async () => {
  const { resetLinkStore } = await import("../src/agent-session/acpmux/chips/linkStore");
  const urls = Array.from({ length: 33 }, (_, n) => `https://reply${n}.example/read`);
  const asked: string[] = [];
  await renderContent(asked, await transcript(urls.join("\n\n")));
  expect(asked).toEqual(urls.slice(0, 32));
  expect(host.querySelectorAll("img.cv-chip__favicon")).toHaveLength(32);
  // Remounting chips does not restore the budget.
  await renderContent(asked, null);
  await renderContent(asked, await transcript(urls[32]!));
  expect(asked).toHaveLength(32);
  await renderContent(asked, null);
  resetLinkStore();
  await renderContent(asked, await transcript(urls[32]!));
  expect(asked).toEqual([...urls.slice(0, 32), urls[32]!]);
});

test("held icons still show outside replies, but cached passive icons do not", async () => {
  const { seedLinkStore } = await import("../src/agent-session/acpmux/chips/linkStore");
  const { Markdown } = await import("../src/agent-session/acpmux/conversation/Markdown");
  const held = "https://held.example/read";
  seedLinkStore({ sites: { [held]: { icon: ICON } } });
  const asked: string[] = [];
  const passive = "https://cached.example/read";
  await renderContent(asked, await transcript(passive));
  expect(asked).toEqual([passive]);
  await renderContent(asked, <Markdown>{`${held} ${passive}`}</Markdown>);
  expect(host.querySelectorAll("img.cv-chip__favicon")).toHaveLength(1);
  expect(host.querySelector("a.cv-chip img")?.getAttribute("src")).toBe(ICON);
  expect(asked).toEqual([passive]);
});
