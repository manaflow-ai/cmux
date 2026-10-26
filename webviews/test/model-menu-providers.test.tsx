// Lawrence 2026-10-22, on an OpenCode chat's model menu that listed one model per provider ("DeepSeek
// V4 Pro [New]", "OpenRouter/DeepSeek V4 Pro", "DeepSeek/DeepSeek V4 Pro", ...): "spacing + needs
// search", "we should just have a standard model picker". The menu lists each model once, names the
// provider its row lands at the row's trailing edge, and a Provider row switches the running model's
// provider. The real ModelPicker and menu, in JSDOM.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import type { ModelCombo, ModelPickerProps } from "../src/agent-session/acpmux/modelPickerLayout";

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
  catalog: ModelPickerProps["catalog"] = rail ? railed : openCode,
  providers?: "row" | "submenu" | "expanded",
) {
  const { createRoot } = await import("react-dom/client");
  const { ModelPicker } = await import("../src/agent-session/acpmux/ModelPicker");
  const landed: string[] = [];
  const combos: ModelCombo[] = [];
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
        onCombo={(combo) => combos.push(combo)}
        onEffort={() => undefined}
      />,
    ),
  );
  await act(async () => host.querySelector<HTMLButtonElement>('[data-menu="Model"]')!.click());
  await act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));
  return { landed, combos };
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
        {
          id: "openrouter/qwen/coder-3",
          name: "Coder 3",
          unavailable: "OpenRouter is unavailable",
        },
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
        {
          id: "openrouter/qwen/coder-3",
          name: "Coder 3",
          unavailable: "OpenRouter is unavailable",
        },
        { id: "together/qwen/coder-3", name: "Coder 3" },
      ],
    },
  ];
  await mount("openrouter/qwen/coder-3", true, catalog);
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

test("Starred prefers an available favorite provider", async () => {
  dom.window.localStorage.setItem(
    "cmux.model-picker.favorites",
    JSON.stringify(["openrouter/qwen/coder-3", "together/qwen/coder-3"]),
  );
  const catalog = [
    {
      id: "opencode",
      name: "OpenCode",
      models: [
        { id: "openrouter/qwen/coder-3", name: "Coder 3", unavailable: "offline" },
        { id: "together/qwen/coder-3", name: "Coder 3" },
      ],
    },
  ];
  await mount("openrouter/qwen/coder-3", true, catalog);
  await act(async () => menus()[0]!.querySelector<HTMLElement>('[aria-label="Starred"]')!.click());
  await act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));
  const rows = modelRows(menus()[0]!);
  expect(rows).toHaveLength(1);
  expect(detailOf(rows[0]!)).toBe("Together");
  expect(rows[0]!.hasAttribute("data-disabled")).toBe(false);
});

test("search groups provider offers into one result", async () => {
  await mount(undefined, true, railed);
  await typeSearch("DeepSeek V4 Pro");
  const rows = modelRows(menus()[0]!);
  expect(rows.filter((row) => nameOf(row) === "DeepSeek V4 Pro")).toHaveLength(1);
});

test("search keeps the running provider selected", async () => {
  await mount("deepseek/deepseek-v4-pro", true, railed);
  await typeSearch("DeepSeek V4 Pro");
  const rows = modelRows(menus()[0]!);
  expect(rows.filter((row) => nameOf(row) === "DeepSeek V4 Pro")).toHaveLength(1);
  expect(rows.find((row) => nameOf(row) === "DeepSeek V4 Pro")?.getAttribute("aria-checked")).toBe("true");
});

test("search falls back to an available provider when current is unavailable", async () => {
  const catalog = [
    {
      id: "opencode",
      name: "OpenCode",
      models: [
        { id: "openrouter/qwen/coder-3", name: "Coder 3", unavailable: "offline" },
        { id: "together/qwen/coder-3", name: "Coder 3" },
      ],
    },
  ];
  await mount("openrouter/qwen/coder-3", true, catalog);
  await typeSearch("Coder 3");
  const rows = modelRows(menus()[0]!);
  expect(rows).toHaveLength(1);
  expect(rows[0]!.hasAttribute("data-disabled")).toBe(false);
});

test("duplicate bare catalog rows remain one compact row", async () => {
  const catalog = [
    {
      id: "opencode",
      name: "OpenCode",
      models: [
        { id: "claude-sonnet-5-5", name: "Sonnet 5.5" },
        { id: "claude-sonnet-5-5", name: "Sonnet 5.5", unavailable: "offline" },
      ],
    },
  ];
  await mount(undefined, true, catalog);
  expect(modelRows(menus()[0]!).filter((row) => nameOf(row) === "Sonnet 5.5")).toHaveLength(1);
});

test("a current duplicate's available landing stays in the compact picks", async () => {
  const catalog = [
    {
      id: "opencode",
      name: "OpenCode",
      models: [
        { id: "model-a", name: "Model A" },
        { id: "model-b", name: "Model B" },
        { id: "model-c", name: "Model C" },
        { id: "model-d", name: "Model D" },
        { id: "openrouter/qwen/Coder-3", name: "Coder 3", unavailable: "offline" },
        { id: "openrouter/qwen/coder-3", name: "Coder 3" },
      ],
    },
  ];
  await mount("openrouter/qwen/Coder-3", true, catalog);
  expect(modelRows(menus()[0]!).map(nameOf)).toContain("Coder 3");
});

test("expanded search reserves provider rows for each logical result", async () => {
  const catalog = [
    {
      id: "opencode",
      name: "OpenCode",
      models: Array.from({ length: 18 }, (_, index) =>
        (index < 9 ? ["openrouter"] : ["openrouter", "together", "groq", "fireworks", "opencode"]).map((provider) => ({
          id: `${provider}/model-${index}`,
          name: `${index < 9 ? "Model" : "Tail"} ${index}`,
        })),
      ).flat(),
    },
  ];
  await mount(undefined, true, catalog, "expanded");
  await typeSearch("Tail");
  const body = menus()[0]!.querySelector<HTMLElement>(".acpmux-quick-body")!;
  const spacerRows = body
    .querySelector<HTMLElement>(".acpmux-quick-spacer")!
    .querySelectorAll(":scope > .acpmux-quick-item").length;
  const shownRows = body.querySelectorAll('[role^="menuitem"]').length;
  expect(spacerRows).toBeGreaterThanOrEqual(shownRows);
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
      models: Array.from({ length: 12 }, (_, index) => ({
        id: `model-${index}`,
        name: `Model ${index}`,
      })),
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
          {
            id: "opencode/deepseek-v4-pro",
            name: "DeepSeek V4 Pro",
            family: "opencode",
            provider: "OpenCode",
          },
          {
            id: "deepseek/deepseek-v4-pro",
            name: "DeepSeek V4 Pro",
            family: "opencode",
            provider: "DeepSeek",
          },
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
      expect(heldWidths, `${name}'s ${nameOf(row)}`).toContainEqual({
        label: nameOf(row),
        value: detailOf(row),
      });
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

test("the submenu slider receives focus before an animation frame", async () => {
  const { createRoot } = await import("react-dom/client");
  const { EffortTrack } = await import("../src/agent-session/acpmux/EffortTrack");
  const frame = scope.requestAnimationFrame;
  scope.requestAnimationFrame = () => 0;
  try {
    root = createRoot(host);
    await act(async () =>
      root!.render(
        <EffortTrack
          efforts={[
            { id: "low", name: "Low" },
            { id: "high", name: "High" },
          ]}
          current="low"
          onPick={() => undefined}
          focusOnMount
        />,
      ),
    );
    expect(dom.window.document.activeElement).toBe(host.querySelector(".acpmux-effort-range"));
  } finally {
    scope.requestAnimationFrame = frame;
  }
});

for (const providers of ["submenu", "expanded"] as const) {
  test(`searched ${providers} providers land their own effort IDs`, async () => {
    const catalog = [
      {
        id: "opencode",
        name: "OpenCode",
        models: [
          { id: "openrouter/qwen/coder-3", name: "Coder 3", efforts: ["high"], fast: true },
          { id: "together/qwen/coder-3", name: "Coder 3", efforts: ["HIGH"], fast: true },
        ],
      },
    ];
    const { combos } = await mount("openrouter/qwen/coder-3", true, catalog, providers);
    await typeSearch("Coder high fast");
    if (providers === "submenu") {
      const row = menus()[0]!.querySelector<HTMLElement>(".acpmux-quick-sub")!;
      await act(async () => row.click());
      await act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));
    }
    const together = modelRows(menus().at(-1)!).find((row) => nameOf(row) === "Together")!;
    expect(together).toBeDefined();
    await act(async () => together.click());
    expect(combos).toEqual([{ harness: "opencode", model: "together/qwen/coder-3", effort: "HIGH", fast: true }]);
  });
}

test("expanded search reserves enabled folder-profile models outside the rail", async () => {
  const catalog: ModelPickerProps["catalog"] = [
    { id: "opencode", name: "OpenCode", models: [{ id: "ordinary", name: "Ordinary" }] },
    {
      id: "folder-profile",
      name: "Folder profile",
      folder: { folder: "/project", state: "enabled" },
      models: Array.from({ length: 9 }, (_, index) =>
        ["openrouter", "together", "groq", "fireworks", "opencode"].map((provider) => ({
          id: `${provider}/model-${index}`,
          name: `Folder model ${index}`,
        })),
      ).flat(),
    },
  ];
  await mount("ordinary", true, catalog, "expanded");
  const spacer = menus()[0]!.querySelector<HTMLElement>(".acpmux-quick-spacer")!;
  const held = spacer.querySelectorAll(":scope > .acpmux-quick-item").length;
  await typeSearch("Folder model");
  expect(modelRows(menus()[0]!)).toHaveLength(45);
  expect(held).toBeGreaterThanOrEqual(55); // Nine group heads, 45 offers and the query label.
  expect(spacer.querySelectorAll(":scope > .acpmux-quick-item")).toHaveLength(held);
});

test("every expanded provider width probe reserves the rendered radio marker column", async () => {
  await mount(undefined, true, railed, "expanded");
  const popup = menus()[0]!;
  const probes = [...popup.querySelectorAll<HTMLElement>(".acpmux-quick-probe .acpmux-quick-offer")];
  expect(probes.length).toBeGreaterThan(1);
  for (const probe of probes) expect(probe.querySelector(".ui-menu-check"), probe.textContent ?? "").not.toBeNull();
  for (const row of popup.querySelectorAll(".acpmux-quick-list .acpmux-quick-offer"))
    expect(row.querySelector(".ui-menu-check")).not.toBeNull();
});

for (const providers of ["row", "submenu", "expanded"] as const) {
  test(`fixed-harness ${providers} search holds the unfiltered list extent`, async () => {
    await mount(undefined, false, openCode, providers);
    const popup = menus()[0]!;
    const spacer = popup.querySelector<HTMLElement>(".acpmux-quick-spacer");
    expect(spacer).not.toBeNull();
    const held = spacer!.querySelectorAll(":scope > .acpmux-quick-item").length;
    const width = spacer!.querySelector(".acpmux-quick-probe")!.innerHTML;
    expect(held).toBeGreaterThanOrEqual(modelRows(popup).length);
    await typeSearch("no matching model");
    expect(modelRows(popup)).toHaveLength(0);
    expect(spacer!.querySelectorAll(":scope > .acpmux-quick-item")).toHaveLength(held);
    expect(spacer!.querySelector(".acpmux-quick-probe")!.innerHTML).toBe(width);
    await typeSearch("DeepSeek");
    expect(modelRows(popup).length).toBeLessThanOrEqual(held);
  });
}
