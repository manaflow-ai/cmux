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
  // Each key from the window; its functions (getComputedStyle, requestAnimationFrame) bound to it.
  const win = dom.window as unknown as Record<string, unknown>;
  for (const key of keys) {
    const value = win[key];
    scope[key] = typeof value === "function" && /^[a-z]/.test(key) ? value.bind(dom.window) : value;
  }
  scope.IS_REACT_ACT_ENVIRONMENT = true;
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

  test("one provider's two rows with the same last id part are two models", async () => {
    const { groupVariants } = await variants();
    const groups = groupVariants([
      { id: "openrouter/qwen/coder-3", name: "OpenRouter/Coder 3" },
      { id: "openrouter/mistral/coder-3", name: "OpenRouter/Coder 3" },
      { id: "together/qwen/coder-3", name: "Together/Coder 3" },
    ]);
    expect(groups.map((group) => group.offers.map((offer) => offer.model.id))).toEqual([
      ["openrouter/qwen/coder-3", "together/qwen/coder-3"],
      ["openrouter/mistral/coder-3"],
    ]);
  });

  // Primary review at 68a5f69a: the third row joined the Qwen model, so its Together row would land
  // Mistral's model in place of Qwen's.
  test("a provider's row joins the model of its own owner, not the first with the same last id part", async () => {
    const { groupVariants } = await variants();
    const groups = groupVariants([
      { id: "openrouter/qwen/coder-3", name: "OpenRouter/Coder 3" },
      { id: "openrouter/mistral/coder-3", name: "OpenRouter/Coder 3" },
      { id: "together/mistral/coder-3", name: "Together/Coder 3" },
    ]);
    expect(groups.map((group) => group.offers.map((offer) => offer.model.id))).toEqual([
      ["openrouter/qwen/coder-3"],
      ["openrouter/mistral/coder-3", "together/mistral/coder-3"],
    ]);
  });

  test("a row that names no owner joins only the one model it can be", async () => {
    const { groupVariants } = await variants();
    // Two owners serve a coder-3: a bare row names neither, so it stays its own model.
    const ambiguous = groupVariants([
      { id: "openrouter/qwen/coder-3", name: "OpenRouter/Coder 3" },
      { id: "together/mistral/coder-3", name: "Together/Coder 3" },
      { id: "groq/coder-3", name: "Groq/Coder 3" },
    ]);
    expect(ambiguous.map((group) => group.offers.map((offer) => offer.model.id))).toEqual([
      ["openrouter/qwen/coder-3"],
      ["together/mistral/coder-3"],
      ["groq/coder-3"],
    ]);
    // An owner's own bare row ("mistral/coder-3") is that owner's model.
    const owned = groupVariants([
      { id: "openrouter/qwen/coder-3", name: "OpenRouter/Coder 3" },
      { id: "together/mistral/coder-3", name: "Together/Coder 3" },
      { id: "mistral/coder-3", name: "Mistral/Coder 3" },
    ]);
    expect(owned.map((group) => group.offers.map((offer) => offer.model.id))).toEqual([
      ["openrouter/qwen/coder-3"],
      ["together/mistral/coder-3", "mistral/coder-3"],
    ]);
    // One owner: every provider's row is that model, bare rows included, whichever comes first.
    const one = groupVariants([
      { id: "opencode/deepseek-v4-pro", name: "DeepSeek V4 Pro" },
      { id: "openrouter/deepseek/deepseek-v4-pro", name: "OpenRouter/DeepSeek V4 Pro" },
      { id: "deepseek/deepseek-v4-pro", name: "DeepSeek/DeepSeek V4 Pro" },
    ]);
    expect(one.map((group) => group.offers.map((offer) => offer.provider))).toEqual([
      ["OpenCode", "OpenRouter", "DeepSeek"],
    ]);
  });

  test("the running provider's row is the one its model lands", async () => {
    const { groupVariants } = await variants();
    expect(groupVariants(rows, "deepseek/deepseek-v4-pro")[0]!.model.id).toBe("deepseek/deepseek-v4-pro");
  });

  test("a bare model's bracketed tag is not repeated in its group name", async () => {
    const { groupVariants } = await variants();
    expect(groupVariants([{ id: "claude-opus-5-5", name: "Opus 5.5 [New]" }])).toMatchObject([
      { name: "Opus 5.5", tag: "New" },
    ]);
  });

  test("duplicate provider rows stay one offer and preserve the running row", async () => {
    const { groupVariants } = await variants();
    const rows = [
      { id: "openrouter/qwen/Coder-3", name: "OpenRouter/Coder 3" },
      { id: "openrouter/qwen/coder-3", name: "OpenRouter/Coder 3" },
    ];
    const groups = groupVariants(rows, rows[1]!.id);
    expect(groups).toHaveLength(1);
    expect(groups[0]!.offers).toHaveLength(1);
    expect(groups[0]!.offers[0]!.model.id).toBe(rows[1]!.id);
    expect(groups[0]!.model.id).toBe(rows[1]!.id);
  });

  test("duplicate provider retention chooses an available row in either order", async () => {
    const { groupVariants } = await variants();
    const available = { id: "openrouter/qwen/coder-3", name: "OpenRouter/Coder 3" };
    const unavailable = {
      id: "openrouter/qwen/Coder-3",
      name: "OpenRouter/Coder 3",
      unavailable: "offline",
    };
    for (const rows of [
      [available, unavailable],
      [unavailable, available],
    ]) {
      const groups = groupVariants(rows, unavailable.id);
      expect(groups[0]!.offers[0]!.model.id).toBe(available.id);
    }
  });

  test("ambiguous owner aliases stay grouped by provider and preserve distinct providers", async () => {
    const { groupVariants } = await variants();
    const groups = groupVariants([
      { id: "openrouter/qwen/coder-3", name: "Qwen/Coder 3" },
      { id: "together/mistral/coder-3", name: "Mistral/Coder 3" },
      { id: "groq/Coder-3", name: "Groq/Coder 3" },
      { id: "groq/coder-3", name: "Groq/Coder 3" },
    ]);
    expect(groups).toHaveLength(3);
    expect(groups.map((group) => group.offers.map((offer) => offer.model.id))).toEqual([
      ["openrouter/qwen/coder-3"],
      ["together/mistral/coder-3"],
      ["groq/Coder-3"],
    ]);
  });

  test("provider identity deduplicates by path while retaining distinct routes", async () => {
    const { groupVariants } = await variants();
    const groups = groupVariants([
      { id: "openrouter/qwen/coder-3", name: "Qwen/Coder 3" },
      { id: "together/qwen/coder-3", name: "Qwen/Coder 3" },
      { id: "openrouter/qwen/Coder-3", name: "Qwen/Coder 3" },
    ]);
    expect(groups).toHaveLength(1);
    expect(groups[0]!.offers.map((offer) => offer.model.id)).toEqual([
      "openrouter/qwen/coder-3",
      "together/qwen/coder-3",
    ]);
  });

  test("provider labels follow the route when names carry an owner", async () => {
    const { providerOf } = await variants();
    expect(providerOf({ id: "openrouter/qwen/coder-3", name: "Qwen/Coder 3" }).provider).toBe("OpenRouter");
    expect(providerOf({ id: "together/mistral/coder-3", name: "Mistral/Coder 3" }).provider).toBe("Together");
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

// A rail beside it: another harness whose one model two providers serve, and one with plain models.
// OpenCode lists more models than the compact rows hold, so some are under More models.
const railed = [
  {
    ...openCode[0]!,
    models: [
      ...openCode[0]!.models,
      { id: "openrouter/deepseek/DeepSeek-v4-pro", name: "OpenRouter/DeepSeek V4 Pro" },
      { id: "openrouter/meta/llama-scout", name: "OpenRouter/Llama Scout" },
      { id: "together/meta/llama-scout", name: "Together/Llama Scout" },
      { id: "mistral/codestral", name: "Mistral/Codestral" },
    ],
  },
  {
    id: "pi",
    name: "Pi",
    models: [
      { id: "together/qwen-3.5-coder", name: "Together/Qwen 3.5 Coder" },
      { id: "fireworks/qwen-3.5-coder", name: "Fireworks/Qwen 3.5 Coder" },
    ],
  },
  {
    id: "claude",
    name: "Claude Code",
    models: [
      { id: "claude-opus-5-5", name: "Opus 5.5" },
      { id: "claude-sonnet-5-5", name: "Sonnet 5.5" },
    ],
  },
];

async function mount(
  model = "opencode/deepseek-v4-pro",
  rail = false,
  catalog = rail ? railed : openCode,
  providers?: "row" | "submenu" | "expanded",
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
        harnessFixed={!rail}
        quick={providers ? { providers } : {}}
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
const typeSearch = async (text: string) => {
  const input = menus()[0]!.querySelector<HTMLInputElement>(".acpmux-quick-search input")!;
  Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!.call(input, text);
  await act(async () => input.dispatchEvent(new dom.window.Event("input", { bubbles: true })));
  await act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));
};

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

test("a chat on another provider's row of a model checks that model's one row and names that provider", async () => {
  await mount("deepseek/deepseek-v4-pro");
  const pro = modelRows(menus()[0]!).find((row) => nameOf(row) === "DeepSeek V4 Pro")!;
  expect(pro.getAttribute("aria-checked")).toBe("true");
  expect(detailOf(pro)).toBe("DeepSeek");
});

test("More models names the provider each of its models lands, each model once", async () => {
  await mount(undefined, true);
  const more = [...menus()[0]!.querySelectorAll<HTMLElement>('[role="menuitem"]')].find((item) =>
    item.textContent?.startsWith("More models"),
  )!;
  expect(more).toBeDefined();
  await act(async () => more.click());
  await act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));
  const rows = modelRows(menus().at(-1)!);
  expect(rows.length).toBeGreaterThan(0);
  const names = rows.map(nameOf);
  expect(new Set(names).size).toBe(names.length);
  // Every OpenCode row is a provider's: its provider is at the row's end.
  for (const row of rows) expect(detailOf(row), nameOf(row)).not.toBe("");
});

test("an available alternate provider keeps a grouped row enabled", async () => {
  const catalog = [
    {
      id: "opencode",
      name: "OpenCode",
      models: [
        { id: "openrouter/qwen/coder-3", name: "Coder 3", unavailable: "OpenRouter is unavailable" },
        { id: "together/qwen/coder-3", name: "Coder 3" },
      ],
    },
  ];
  await mount(undefined, true, catalog);
  const rows = modelRows(menus()[0]!);
  expect(rows).toHaveLength(1);
  expect(detailOf(rows[0]!)).toBe("Together");
  expect(rows[0]!.hasAttribute("data-disabled")).toBe(false);
});

test("fixed-harness filtering keeps bare owners in the right grouped model", async () => {
  const catalog = [
    {
      id: "opencode",
      name: "OpenCode",
      models: [
        { id: "openrouter/qwen/coder-3", name: "Coder 3" },
        { id: "together/mistral/coder-3", name: "Coder 3", unavailable: "Together is unavailable" },
        { id: "mistral/coder-3", name: "Coder 3" },
      ],
    },
  ];
  await mount("openrouter/qwen/coder-3", false, catalog);
  const rows = modelRows(menus()[0]!);
  expect(rows.map(detailOf)).toEqual(["OpenRouter", "Mistral"]);
});

test("an unavailable current provider keeps its available grouped landing row", async () => {
  const catalog = [
    {
      id: "opencode",
      name: "OpenCode",
      models: [
        { id: "openrouter/qwen/coder-3", name: "Coder 3", unavailable: "OpenRouter is unavailable" },
        { id: "together/qwen/coder-3", name: "Coder 3" },
      ],
    },
  ];
  await mount("openrouter/qwen/coder-3", false, catalog);
  const rows = modelRows(menus()[0]!);
  expect(rows).toHaveLength(1);
  expect(detailOf(rows[0]!)).toBe("Together");
  expect(rows[0]!.hasAttribute("data-disabled")).toBe(false);
});

test("duplicate catalog IDs retain the available current offer", async () => {
  const catalog = [
    {
      id: "opencode",
      name: "OpenCode",
      models: [
        { id: "openrouter/qwen/coder-3", name: "Coder 3", unavailable: "temporarily offline" },
        { id: "openrouter/qwen/coder-3", name: "Coder 3" },
      ],
    },
  ];
  await mount("openrouter/qwen/coder-3", false, catalog);
  const rows = modelRows(menus()[0]!);
  expect(rows).toHaveLength(1);
  expect(rows[0]!.hasAttribute("data-disabled")).toBe(false);
});

test("the Starred rail groups provider offers into one model row", async () => {
  dom.window.localStorage.setItem("cmux.model-picker.favorites", JSON.stringify(["openrouter/qwen/coder-3"]));
  const catalog = [
    {
      id: "opencode",
      name: "OpenCode",
      models: [
        { id: "openrouter/qwen/coder-3", name: "Coder 3" },
        { id: "together/qwen/coder-3", name: "Coder 3" },
      ],
    },
  ];
  await mount("openrouter/qwen/coder-3", true, catalog);
  const starred = menus()[0]!.querySelector<HTMLElement>('[aria-label="Starred"]');
  expect(starred).toBeDefined();
  await act(async () => starred!.click());
  await act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));
  const rows = modelRows(menus()[0]!);
  expect(rows).toHaveLength(1);
  expect(nameOf(rows[0]!)).toBe("Coder 3");
  expect(detailOf(rows[0]!)).toBe("OpenRouter");
});

test("search groups provider offers into one result", async () => {
  await mount(undefined, true, railed);
  await typeSearch("DeepSeek V4 Pro");
  const rows = modelRows(menus()[0]!);
  expect(rows.filter((row) => nameOf(row) === "DeepSeek V4 Pro")).toHaveLength(1);
});

test("a running model stays in the compact picks after an unavailable group", async () => {
  const catalog = [
    {
      id: "opencode",
      name: "OpenCode",
      models: [
        { id: "offline-model", name: "Offline model", unavailable: "offline" },
        { id: "model-a", name: "Model A" },
        { id: "model-b", name: "Model B" },
        { id: "model-c", name: "Model C" },
        { id: "model-d", name: "Model D" },
        { id: "model-e", name: "Model E" },
      ],
    },
  ];
  await mount("model-e", true, catalog);
  expect(modelRows(menus()[0]!).map(nameOf)).toContain("Model E");
});

test("search spacer reserves the query group label", async () => {
  const catalog = [
    {
      id: "opencode",
      name: "OpenCode",
      models: Array.from({ length: 12 }, (_, index) => ({ id: `model-${index}`, name: `Model ${index}` })),
    },
  ];
  await mount(undefined, true, catalog);
  await typeSearch("Model");
  const body = menus()[0]!.querySelector<HTMLElement>(".acpmux-quick-body")!;
  const spacerRows = body
    .querySelector<HTMLElement>(".acpmux-quick-spacer")!
    .querySelectorAll(":scope > .acpmux-quick-item").length;
  expect(modelRows(menus()[0]!).length + 1).toBeLessThanOrEqual(spacerRows);
});

// Astra on #25175: the Provider row is a row of the chat's tab, so the held list height and width
// (QuickModelMenu's tabExtent and width probe) count it, or the chat's tab overflows the held
// height and the menu's top edge moves as the pointer crosses the rail.
test("the held list height and width count the chat tab's Provider row, on every rail tab", async () => {
  const { tabExtent } = await import("../src/agent-session/acpmux/QuickModelMenu");
  const offered = {
    id: "opencode",
    name: "OpenCode",
    models: [
      {
        id: "opencode/deepseek-v4-pro",
        name: "DeepSeek V4 Pro",
        family: "opencode",
        provider: "OpenCode",
        offers: [
          { id: "opencode/deepseek-v4-pro", name: "DeepSeek V4 Pro", family: "opencode", provider: "OpenCode" },
          { id: "deepseek/deepseek-v4-pro", name: "DeepSeek V4 Pro", family: "opencode", provider: "DeepSeek" },
        ],
      },
    ],
    more: [],
  };
  const families = { list: [offered], current: offered.id, onPick: () => undefined };
  const extent = (providers: "row" | "submenu" | "expanded", current = "opencode/deepseek-v4-pro") =>
    tabExtent(offered, { families, levels: 0, current, providers });
  // The model's row and, for the running model, its Provider row.
  expect(extent("row")).toEqual({ rows: 2, separators: 1 });
  // Not the running model: no Provider row.
  expect(extent("row", "zai/glm-5.3")).toEqual({ rows: 1, separators: 1 });
  // A submenu of providers is the model's one row; the expanded version heads its two providers.
  expect(extent("submenu")).toEqual({ rows: 1, separators: 1 });
  expect(extent("expanded")).toEqual({ rows: 3, separators: 1 });

  await mount(undefined, true);
  const body = () => menus()[0]!.querySelector<HTMLElement>(".acpmux-quick-body")!;
  const spacer = () => {
    const node = body().querySelector<HTMLElement>(".acpmux-quick-spacer")!;
    return {
      rows: node.querySelectorAll(":scope > .acpmux-quick-item").length,
      separators: node.querySelectorAll(":scope > .ui-separator").length,
    };
  };
  const probe = () =>
    [...body().querySelectorAll<HTMLElement>(".acpmux-quick-probe > .acpmux-quick-item")].map((row) => ({
      label: row.querySelector(".acpmux-menu-label")?.textContent ?? "",
      value: row.querySelector(".acpmux-quick-value")?.textContent ?? "",
    }));
  const held = spacer();
  const heldWidths = probe();
  // Search still exposes provider offers individually, so the held rail reserves nine raw matches
  // even when grouping leaves fewer than nine model rows.
  expect(held.rows).toBeGreaterThanOrEqual(9);
  expect(heldWidths).toContainEqual({ label: "Provider", value: "OpenCode" });
  const tabs = [...menus()[0]!.querySelectorAll<HTMLElement>(".acpmux-quick-rail-tab")].map((tab) =>
    tab.getAttribute("aria-label")!,
  );
  expect([...tabs].sort()).toEqual(["Claude Code", "OpenCode", "Pi"]);
  for (const name of tabs) {
    const tab = menus()[0]!.querySelector<HTMLElement>(`.acpmux-quick-rail-tab[aria-label="${name}"]`)!;
    await act(async () => tab.click());
    await act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));
    expect(spacer(), `the held height on ${name}`).toEqual(held);
    expect(probe(), `the held width on ${name}`).toEqual(heldWidths);
    const shown = body().querySelectorAll('[role^="menuitem"]').length;
    expect(shown, `${name}'s rows`).toBeLessThanOrEqual(held.rows);
    // Every row's name and trailing provider is in the probe, so the held width fits it.
    for (const row of modelRows(menus()[0]!))
      expect(heldWidths, `${name}'s ${nameOf(row)}`).toContainEqual({ label: nameOf(row), value: detailOf(row) });
  }
});

test("submenu width probes use only the rendered chevron marker", async () => {
  await mount(undefined, true, railed, "submenu");
  const probe = [...menus()[0]!.querySelectorAll<HTMLElement>(".acpmux-quick-probe > .acpmux-quick-item")].find(
    (row) => row.querySelector(".acpmux-menu-label")?.textContent === "DeepSeek V4 Pro",
  );
  expect(probe).toBeDefined();
  expect(probe?.querySelector(".ui-submenu-chevron")).not.toBeNull();
  expect(probe?.querySelector(".ui-menu-check, .ui-menu-shortcut")).toBeNull();
});
