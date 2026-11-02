// Lawrence 2026-10-22, on an OpenCode chat's model menu that listed one model per provider ("DeepSeek
// V4 Pro [New]", "OpenRouter/DeepSeek V4 Pro", "DeepSeek/DeepSeek V4 Pro", ...): "spacing + needs
// search", "we should just have a standard model picker". The menu lists each model once, names the
// provider its row lands at the row's trailing edge, and a Provider row switches the running model's
// provider. The real ModelPicker and menu, in JSDOM.
import { afterAll, afterEach, beforeAll, describe, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "IS_REACT_ACT_ENVIRONMENT",
  "HTMLElement",
  "Element",
  "Node",
  "ShadowRoot",
  "MouseEvent",
  "KeyboardEvent",
  "Event",
  "CustomEvent",
  "customElements",
  "MutationObserver",
  "CSSStyleSheet",
  "DocumentFragment",
  "SVGElement",
  "HTMLTemplateElement",
  "localStorage",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", {
    pretendToBeVisual: true,
    url: "https://cmux.test/",
  });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    IS_REACT_ACT_ENVIRONMENT: true,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    ShadowRoot: dom.window.ShadowRoot,
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    Event: dom.window.Event,
    CustomEvent: dom.window.CustomEvent,
    customElements: dom.window.customElements,
    MutationObserver: dom.window.MutationObserver,
    CSSStyleSheet: dom.window.CSSStyleSheet,
    DocumentFragment: dom.window.DocumentFragment,
    SVGElement: dom.window.SVGElement,
    HTMLTemplateElement: dom.window.HTMLTemplateElement,
    localStorage: dom.window.localStorage,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
  });
  host = dom.window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  dom.window.localStorage.clear();
  for (const popup of dom.window.document.querySelectorAll(".acpmux-quick-menu")) popup.remove();
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

const variants = () => import("../src/agent-session/acpmux/modelVariants");

describe("groupVariants", () => {
  const rows = [
    { id: "opencode/deepseek-v4-pro", name: "DeepSeek V4 Pro [New]" },
    { id: "openrouter/deepseek/deepseek-v4-pro", name: "OpenRouter/DeepSeek V4 Pro" },
    { id: "deepseek/deepseek-v4-pro", name: "DeepSeek/DeepSeek V4 Pro" },
    { id: "openrouter/deepseek/deepseek-chat", name: "OpenRouter/DeepSeek Chat" },
    { id: "claude-opus-5-5", name: "Opus 5.5" },
    { id: "claude-opus-5-5-copy", name: "Opus 5.5" },
  ];

  test("a provider's row names its provider, its model and its note", async () => {
    const { providerOf } = await variants();
    expect(providerOf(rows[0]!)).toEqual({
      provider: "OpenCode",
      key: "deepseek-v4-pro",
      name: "DeepSeek V4 Pro",
      tag: "New",
    });
    expect(providerOf(rows[1]!)).toEqual({
      provider: "OpenRouter",
      key: "deepseek-v4-pro",
      name: "DeepSeek V4 Pro",
    });
    expect(providerOf(rows[4]!)).toEqual({ key: "claude-opus-5-5", name: "Opus 5.5" });
  });

  test("the rows of one model are one, in first-row order; a bare id is its own model", async () => {
    const { groupVariants } = await variants();
    const groups = groupVariants(rows);
    expect(groups.map((group) => [group.name, group.offers.map((offer) => offer.provider)])).toEqual([
      ["DeepSeek V4 Pro", ["OpenCode", "OpenRouter", "DeepSeek"]],
      ["DeepSeek Chat", ["OpenRouter"]],
      ["Opus 5.5", [""]],
      ["Opus 5.5", [""]],
    ]);
    expect(groups[0]!.model.id).toBe("opencode/deepseek-v4-pro");
    expect(groups[0]!.tag).toBe("New");
  });

  test("two vendors' models that share a last id segment stay two models", async () => {
    const { groupVariants } = await variants();
    const groups = groupVariants([
      { id: "openrouter/qwen/coder-3", name: "OpenRouter/Coder 3" },
      { id: "together/mistral/coder-3", name: "Together/Coder 3" },
      { id: "qwen/coder-3", name: "Qwen/Coder 3" },
    ]);
    expect(groups.map((group) => group.offers.map((offer) => offer.model.id))).toEqual([
      ["openrouter/qwen/coder-3", "qwen/coder-3"],
      ["together/mistral/coder-3"],
    ]);
  });

  test("a row that names no vendor joins its own vendor's model, whatever the order", async () => {
    const { groupVariants } = await variants();
    const ids = (rows: { id: string }[]) =>
      groupVariants(rows.map((row) => ({ ...row, name: row.id }))).map((group) =>
        group.offers.map((offer) => offer.model.id),
      );
    expect(
      ids([{ id: "together/mistral/coder-3" }, { id: "openrouter/qwen/coder-3" }, { id: "qwen/coder-3" }]),
    ).toEqual([["together/mistral/coder-3"], ["openrouter/qwen/coder-3", "qwen/coder-3"]]);
    expect(
      ids([{ id: "qwen/coder-3" }, { id: "together/mistral/coder-3" }, { id: "openrouter/qwen/coder-3" }]),
    ).toEqual([["qwen/coder-3", "openrouter/qwen/coder-3"], ["together/mistral/coder-3"]]);
    // Two vendors and a provider that is neither: it is its own model.
    expect(
      ids([{ id: "together/mistral/coder-3" }, { id: "openrouter/qwen/coder-3" }, { id: "opencode/coder-3" }]),
    ).toEqual([["together/mistral/coder-3"], ["openrouter/qwen/coder-3"], ["opencode/coder-3"]]);
  });

  test("the running provider's row is the one its model lands", async () => {
    const { groupVariants } = await variants();
    expect(groupVariants(rows, "deepseek/deepseek-v4-pro")[0]!.model.id).toBe("deepseek/deepseek-v4-pro");
  });
});

const openCode = [
  {
    id: "opencode",
    name: "OpenCode",
    models: [
      { id: "opencode/deepseek-v4-pro", name: "DeepSeek V4 Pro [New]" },
      { id: "opencode/deepseek-v4.1-flash", name: "DeepSeek V4.1 Flash" },
      { id: "openrouter/deepseek/deepseek-v4-pro", name: "OpenRouter/DeepSeek V4 Pro" },
      { id: "openrouter/deepseek/deepseek-v4.1-flash", name: "OpenRouter/DeepSeek V4.1 Flash" },
      { id: "openrouter/deepseek/deepseek-chat", name: "OpenRouter/DeepSeek Chat" },
      { id: "deepseek/deepseek-v4-pro", name: "DeepSeek/DeepSeek V4 Pro" },
      { id: "deepseek/deepseek-chat", name: "DeepSeek/DeepSeek Chat" },
      { id: "zai/glm-5.3", name: "Z.ai/GLM 5.3" },
    ],
  },
];

async function mount(
  model: string | undefined = "opencode/deepseek-v4-pro",
  { catalog = openCode, fixed = true }: { catalog?: typeof openCode; fixed?: boolean } = {},
) {
  const { createRoot } = await import("react-dom/client");
  const { ModelPicker } = await import("../src/agent-session/acpmux/ModelPicker");
  const landed: string[] = [];
  root = createRoot(host);
  await act(async () =>
    root!.render(
      <ModelPicker
        catalog={catalog}
        harness="opencode"
        model={model}
        label="DeepSeek V4 Pro"
        efforts={[]}
        recents={[]}
        harnessFixed={fixed}
        quick={{}}
        onLand={(id) => landed.push(id)}
        onEffort={() => undefined}
      />,
    ),
  );
  await act(async () => host.querySelector<HTMLButtonElement>('[data-menu="Model"]')!.click());
  await act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));
  return { landed };
}

const menus = () => [...dom.window.document.querySelectorAll<HTMLElement>(".acpmux-quick-menu")];
const modelRows = (popup: HTMLElement) => [
  ...popup.querySelectorAll<HTMLElement>('.acpmux-quick-item[role="menuitemradio"]'),
];
const nameOf = (row: HTMLElement) => row.querySelector(".acpmux-menu-label")?.textContent ?? "";
const detailOf = (row: HTMLElement) => row.querySelector(".acpmux-quick-value")?.textContent ?? "";

test("an OpenCode chat's menu lists each model once, naming the provider its row lands", async () => {
  await mount();
  const rows = modelRows(menus()[0]!);
  const names = rows.map(nameOf);
  expect(new Set(names).size).toBe(names.length);
  const pro = rows.find((row) => nameOf(row) === "DeepSeek V4 Pro")!;
  expect(pro, names.join(", ")).toBeDefined();
  expect(detailOf(pro)).toBe("OpenCode");
  expect(pro.querySelector(".acpmux-quick-tag")?.textContent).toBe("New");
  expect(pro.getAttribute("aria-checked")).toBe("true");
  expect(names.some((name) => name.includes("/DeepSeek V4 Pro"))).toBe(false);
  // A model one provider serves reads as the others do: its name, then its provider.
  const glm = rows.find((row) => nameOf(row) === "GLM 5.3")!;
  expect(glm, names.join(", ")).toBeDefined();
  expect(detailOf(glm)).toBe("Z.ai");
});

test("the Provider row names the running provider and switches the running model to another", async () => {
  const { landed } = await mount();
  const provider = [...menus()[0]!.querySelectorAll<HTMLElement>('[role="menuitem"]')].find((item) =>
    item.textContent?.startsWith("Provider"),
  )!;
  expect(provider).toBeDefined();
  expect(provider.querySelector(".acpmux-quick-value")?.textContent).toBe("OpenCode");
  await act(async () => provider.click());
  await act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));
  const sub = menus().at(-1)!;
  expect(modelRows(sub).map(nameOf)).toEqual(["OpenCode", "OpenRouter", "DeepSeek"]);
  await act(async () => modelRows(sub)[1]!.click());
  expect(landed).toEqual(["openrouter/deepseek/deepseek-v4-pro"]);
});

test("the Provider row reaches every available provider when the running one is unavailable", async () => {
  const catalog = [
    {
      ...openCode[0]!,
      models: openCode[0]!.models.map((model) =>
        model.id === "opencode/deepseek-v4-pro" ? { ...model, unavailable: "Not on this plan" } : model,
      ),
    },
  ];
  const { landed } = await mount("opencode/deepseek-v4-pro", { catalog });
  const provider = [...menus()[0]!.querySelectorAll<HTMLElement>('[role="menuitem"]')].find((item) =>
    item.textContent?.startsWith("Provider"),
  )!;
  expect(provider).toBeDefined();
  expect(provider.querySelector(".acpmux-quick-value")?.textContent).toBe("OpenCode");
  await act(async () => provider.click());
  await act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));
  const sub = menus().at(-1)!;
  expect(modelRows(sub).map(nameOf)).toEqual(["OpenCode", "OpenRouter", "DeepSeek"]);
  await act(async () => modelRows(sub)[2]!.click());
  expect(landed).toEqual(["deepseek/deepseek-v4-pro"]);
});

test("a chat on another provider's row of a model checks that model's one row and names that provider", async () => {
  await mount("deepseek/deepseek-v4-pro");
  const pro = modelRows(menus()[0]!).find((row) => nameOf(row) === "DeepSeek V4 Pro")!;
  expect(pro.getAttribute("aria-checked")).toBe("true");
  expect(detailOf(pro)).toBe("DeepSeek");
});

const field = () => menus()[0]?.querySelector<HTMLInputElement>(".acpmux-quick-search input") ?? null;
const typeIn = (text: string) =>
  act(async () => {
    const input = field()!;
    Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!.call(input, text);
    input.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
  });

test("a search lists a model several providers serve once, naming its provider", async () => {
  await mount();
  expect(field()).not.toBeNull();
  await typeIn("v4 pro");
  const rows = modelRows(menus()[0]!);
  expect(rows.map(nameOf)).toEqual(["DeepSeek V4 Pro"]);
  expect(detailOf(rows[0]!)).toBe("OpenCode");
});

test("a search for a running model whose provider is unavailable lands an available provider", async () => {
  const catalog = [
    {
      ...openCode[0]!,
      models: openCode[0]!.models.map((model) =>
        model.id === "opencode/deepseek-v4-pro" ? { ...model, unavailable: "Not on this plan" } : model,
      ),
    },
  ];
  const { landed } = await mount("opencode/deepseek-v4-pro", { catalog });
  await typeIn("v4 pro");
  const rows = modelRows(menus()[0]!);
  expect(rows.map(nameOf)).toEqual(["DeepSeek V4 Pro"]);
  expect(rows[0]!.hasAttribute("data-disabled")).toBe(false);
  expect(detailOf(rows[0]!)).toBe("OpenRouter");
  await act(async () => rows[0]!.click());
  expect(landed).toEqual(["openrouter/deepseek/deepseek-v4-pro"]);
});

test("Starred lands an available provider when the running one is unavailable", async () => {
  const catalog = [
    {
      ...openCode[0]!,
      models: openCode[0]!.models.map((model) =>
        model.id === "opencode/deepseek-v4-pro" ? { ...model, unavailable: "Not on this plan" } : model,
      ),
    },
  ];
  dom.window.localStorage.setItem(
    "cmux.model-picker.favorites",
    JSON.stringify(["opencode/deepseek-v4-pro", "openrouter/deepseek/deepseek-v4-pro"]),
  );
  await mount("opencode/deepseek-v4-pro", { catalog, fixed: false });
  const starred = menus()[0]!.querySelector<HTMLButtonElement>('.acpmux-quick-rail-tab[aria-label="Starred"]')!;
  await act(async () => starred.click());
  const rows = modelRows(menus()[0]!);
  expect(rows.map(nameOf)).toEqual(["DeepSeek V4 Pro"]);
  expect(rows[0]!.hasAttribute("data-disabled")).toBe(false);
  expect(detailOf(rows[0]!)).toBe("OpenRouter");
});

test("a New Tab row of a model lands an available provider when the first one is unavailable", async () => {
  const catalog = [
    {
      ...openCode[0]!,
      models: openCode[0]!.models.map((model) =>
        model.id === "opencode/deepseek-v4-pro" ? { ...model, unavailable: "Not on this plan" } : model,
      ),
    },
  ];
  // The chat runs another model, so nothing pins the row to the unavailable provider. The menu
  // lists each family's newest available model (relevantModels.ts, #26071), so the row is in it.
  await mount("zai/glm-5.3", { catalog, fixed: false });
  const pro = menus()
    .flatMap(modelRows)
    .find((row) => nameOf(row) === "DeepSeek V4 Pro")!;
  expect(pro).toBeDefined();
  expect(pro.hasAttribute("data-disabled")).toBe(false);
  expect(detailOf(pro)).toBe("OpenRouter");
});

test("Starred lists a model once when several of its providers are starred", async () => {
  dom.window.localStorage.setItem(
    "cmux.model-picker.favorites",
    JSON.stringify(["opencode/deepseek-v4-pro", "openrouter/deepseek/deepseek-v4-pro"]),
  );
  await mount("zai/glm-5.3", { fixed: false });
  const starred = menus()[0]!.querySelector<HTMLButtonElement>('.acpmux-quick-rail-tab[aria-label="Starred"]')!;
  expect(starred).not.toBeNull();
  await act(async () => starred.click());
  expect(modelRows(menus()[0]!).map(nameOf)).toEqual(["DeepSeek V4 Pro"]);
});

test("More models names each model's provider and tag", async () => {
  const catalog = [
    {
      ...openCode[0]!,
      models: [
        ...openCode[0]!.models,
        { id: "opencode/kimi-k3", name: "Kimi K3 [New]" },
        { id: "opencode/qwen-coder-3", name: "Qwen Coder 3" },
        // Older releases of a family fold under More models (relevantModels.ts, #26071).
        { id: "opencode/kimi-k2", name: "Kimi K2 [Preview]" },
        { id: "opencode/qwen-coder-2.5", name: "Qwen Coder 2.5" },
      ],
    },
  ];
  await mount("opencode/deepseek-v4-pro", { catalog, fixed: false });
  // The default symbols layout names More models "Legacy models".
  const more = [...menus()[0]!.querySelectorAll<HTMLElement>('[role="menuitem"]')].find((item) =>
    item.textContent?.startsWith("Legacy models"),
  )!;
  expect(more).toBeDefined();
  await act(async () => more.click());
  await act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));
  const rows = modelRows(menus().at(-1)!);
  expect(rows.length).toBeGreaterThan(0);
  for (const row of rows) expect(detailOf(row), nameOf(row)).not.toBe("");
  expect(rows.map(nameOf).sort()).toEqual(["Kimi K2", "Qwen Coder 2.5"]);
  const kimi = rows.find((row) => nameOf(row) === "Kimi K2")!;
  expect(kimi.querySelector(".acpmux-quick-tag")?.textContent).toBe("Preview");
  expect(detailOf(kimi)).toBe("OpenCode");
});
