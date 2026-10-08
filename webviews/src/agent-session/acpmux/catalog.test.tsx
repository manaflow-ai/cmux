import { afterAll, describe, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=root></div>", {
  pretendToBeVisual: true,
  virtualConsole: new VirtualConsole(),
});
const globals = globalThis as Record<string, unknown>;
const saved = Object.fromEntries(
  ["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"].map((key) => [key, globals[key]]),
);
Object.assign(globals, {
  window: dom.window,
  document: dom.window.document,
  navigator: dom.window.navigator,
  HTMLElement: dom.window.HTMLElement,
  IS_REACT_ACT_ENVIRONMENT: true,
});
afterAll(() => Object.assign(globals, saved));

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
const { HarnessCatalogCache, useHarnessCatalog } = await import("./catalog");
type Catalog = import("./catalog").HarnessCatalog;

const codex: Catalog = [{ id: "codex", name: "Codex", models: [{ id: "gpt-6-astra" }] }];
const claude: Catalog = [{ id: "claude", name: "Claude", models: [{ id: "claude-sonnet" }] }];
const settle = () =>
  act(async () => {
    for (let pass = 0; pass < 5; pass += 1) await new Promise((resolve) => setTimeout(resolve, 0));
  });

/// A fake direct client that counts catalog requests.
function source(id: number, catalog: Catalog | Error) {
  const client = {
    calls: 0,
    harnesses: async () => {
      client.calls += 1;
      if (catalog instanceof Error) throw catalog;
      return catalog;
    },
  };
  return { id, client };
}

/// Renders `count` pickers that read the catalog and returns what each one saw last.
function mount(
  queryClient: InstanceType<typeof QueryClient>,
  count = 1,
  cache = new HarnessCatalogCache(() => undefined),
) {
  const seen: Catalog[] = [];
  const Picker = ({
    index,
    input,
    fallback,
  }: {
    index: number;
    input: ReturnType<typeof source> | undefined;
    fallback: Catalog;
  }) => {
    seen[index] = useHarnessCatalog(input, fallback, cache);
    return null;
  };
  const root = createRoot(dom.window.document.getElementById("root")!);
  const render = (input: ReturnType<typeof source> | undefined, fallback: Catalog = []) =>
    act(async () =>
      root.render(
        createElement(
          QueryClientProvider,
          { client: queryClient },
          ...Array.from({ length: count }, (_, index) => createElement(Picker, { key: index, index, input, fallback })),
        ),
      ),
    );
  return { seen, render, unmount: () => act(async () => root.unmount()) };
}

describe("harness catalog query", () => {
  test("fetches once from the direct client, shared by every reader", async () => {
    const pane = mount(new QueryClient({ defaultOptions: { queries: { retry: false } } }), 2);
    const first = source(1, codex);
    await pane.render(first);
    await settle();
    expect(pane.seen).toEqual([codex, codex]);
    expect(first.client.calls).toBe(1);
    await pane.render(first);
    await settle();
    expect(first.client.calls).toBe(1);
    await pane.unmount();
  });

  test("without a direct client, the snapshot's catalog is used and nothing is fetched", async () => {
    const pane = mount(new QueryClient());
    await pane.render(undefined, claude);
    await settle();
    expect(pane.seen).toEqual([claude]);
    await pane.unmount();
  });

  test("a new client after a reconnect fetches its own catalog", async () => {
    const pane = mount(new QueryClient({ defaultOptions: { queries: { retry: false } } }));
    await pane.render(source(1, codex));
    await settle();
    const restarted = source(2, claude);
    await pane.render(restarted);
    await settle();
    expect(pane.seen).toEqual([claude]);
    expect(restarted.client.calls).toBe(1);
    await pane.unmount();
  });

  test("a failed request falls back to the snapshot's catalog", async () => {
    const pane = mount(new QueryClient({ defaultOptions: { queries: { retry: false } } }));
    await pane.render(source(1, new Error("acpmux WebSocket closed")), claude);
    await settle();
    expect(pane.seen).toEqual([claude]);
    await pane.unmount();
  });

  test("the cached catalog draws before the first fetch lands, then the fetch replaces it", async () => {
    const storage = new Map<string, string>();
    const cache = new HarnessCatalogCache(
      () =>
        ({
          getItem: (key: string) => storage.get(key) ?? null,
          setItem: (key: string, value: string) => void storage.set(key, value),
        }) as unknown as Storage,
    );
    cache.merge(codex, 1);
    const pane = mount(new QueryClient({ defaultOptions: { queries: { retry: false } } }), 1, cache);
    // Before any client: the cache, not the empty snapshot catalog.
    await pane.render(undefined, []);
    expect(pane.seen).toEqual([codex]);
    let release!: () => void;
    const slow = {
      id: 1,
      client: {
        calls: 0,
        harnesses: () => new Promise<Catalog>((resolve) => (release = () => resolve(claude))),
      },
    };
    await pane.render(slow, []);
    expect(pane.seen).toEqual([codex]);
    await act(async () => release());
    await settle();
    expect(pane.seen).toEqual([claude]);
    // Stored for the next page load.
    expect(
      new HarnessCatalogCache(() => ({ getItem: (key: string) => storage.get(key) ?? null }) as never).read()?.catalog,
    ).toEqual(claude);
    await pane.unmount();
  });
});

describe("harness catalog cache", () => {
  test("a harness whose models are not probed yet keeps its cached ones; one acpmux dropped goes", () => {
    const cache = new HarnessCatalogCache(() => undefined);
    cache.merge(
      [
        { id: "codex", name: "Codex", models: [{ id: "gpt-6-astra" }] },
        { id: "gone", name: "Gone", models: [{ id: "x" }] },
      ],
      1,
    );
    const merged = cache.merge(
      [
        { id: "codex", name: "Codex", models: [] },
        { id: "claude", name: "Claude", models: [{ id: "opus" }] },
      ],
      2,
    );
    expect(merged).toEqual([
      { id: "codex", name: "Codex", models: [{ id: "gpt-6-astra" }] },
      { id: "claude", name: "Claude", models: [{ id: "opus" }] },
    ]);
  });

  test("blocked storage reads as no cache and never throws", () => {
    const cache = new HarnessCatalogCache(() => {
      throw new Error("SecurityError");
    });
    expect(cache.read()).toBeUndefined();
    expect(cache.merge(codex, 1)).toEqual(codex);
  });
});
