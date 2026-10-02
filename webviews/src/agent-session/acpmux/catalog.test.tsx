import { afterAll, describe, expect, test } from "bun:test";
import { JSDOM, VirtualConsole } from "jsdom";

const dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, virtualConsole: new VirtualConsole() });
const globals = globalThis as Record<string, unknown>;
const saved = Object.fromEntries(["window", "document", "navigator", "HTMLElement", "IS_REACT_ACT_ENVIRONMENT"].map((key) => [key, globals[key]]));
Object.assign(globals, { window: dom.window, document: dom.window.document, navigator: dom.window.navigator, HTMLElement: dom.window.HTMLElement, IS_REACT_ACT_ENVIRONMENT: true });
afterAll(() => Object.assign(globals, saved));

const { act, createElement } = await import("react");
const { createRoot } = await import("react-dom/client");
const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
const { useHarnessCatalog } = await import("./catalog");
type Catalog = import("./catalog").HarnessCatalog;

const codex: Catalog = [{ id: "codex", name: "Codex", models: [{ id: "gpt-6-astra" }] }];
const claude: Catalog = [{ id: "claude", name: "Claude", models: [{ id: "claude-sonnet" }] }];
const settle = () => act(async () => { for (let pass = 0; pass < 5; pass += 1) await new Promise((resolve) => setTimeout(resolve, 0)); });

/// A fake direct client that counts catalog requests.
function source(id: number, catalog: Catalog | Error) {
  const client = { calls: 0, harnesses: async () => { client.calls += 1; if (catalog instanceof Error) throw catalog; return catalog; } };
  return { id, client };
}

/// Renders `count` pickers that read the catalog and returns what each one saw last.
function mount(queryClient: InstanceType<typeof QueryClient>, count = 1) {
  const seen: Catalog[] = [];
  const Picker = ({ index, input, fallback }: { index: number; input: ReturnType<typeof source> | undefined; fallback: Catalog }) => { seen[index] = useHarnessCatalog(input, fallback); return null; };
  const root = createRoot(dom.window.document.getElementById("root")!);
  const render = (input: ReturnType<typeof source> | undefined, fallback: Catalog = []) =>
    act(async () => root.render(createElement(QueryClientProvider, { client: queryClient }, ...Array.from({ length: count }, (_, index) => createElement(Picker, { key: index, index, input, fallback })))));
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
});
