// l10n-allow-file: test fixtures.
// Fast mode per harness (Leo 2026-10-21: "the lightning (fast mode) symbol: REMOVE it for Claude, where
// Fast mode lives inside the menu. KEEP it for Codex"). At the composer's boundary: the real composer
// with the real chips, a stand-in mic, and a host that records what the pane sends.
//   - Claude: the composer draws no bolt; the model button's menu ends on a Fast mode checkbox,
//     checked while any tier past off runs, and a click sends the option's on or off value;
//   - Codex: the bolt sits in the box just left of the mic, and the menu has no Fast mode row (the
//     bolt is its one control); a click steps through the offered tiers and back to off;
//   - neither draws an effort control of its own (#20946 brought one back): only the model button
//     names the effort;
//   - the button never says Fast;
//   - a model whose catalog row has no fast mode shows no row, unless fast mode is still on.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
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
  "HTMLInputElement",
  "Element",
  "Node",
  "Text",
  "Range",
  "Selection",
  "ShadowRoot",
  "MouseEvent",
  "KeyboardEvent",
  "InputEvent",
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
  "PointerEvent",
  "FocusEvent",
  "ResizeObserver",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  const w = dom.window as unknown as Record<string, unknown>;
  Object.assign(scope, Object.fromEntries(keys.map((key) => [key, w[key]])), {
    IS_REACT_ACT_ENVIRONMENT: true,
    PointerEvent: w.PointerEvent ?? w.MouseEvent,
    ResizeObserver:
      w.ResizeObserver ??
      class {
        observe() {}
        unobserve() {}
        disconnect() {}
      },
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

type Option = { value: string; name?: string };
type Snapshot = import("../src/agent-session/acpmux/model").AcpmuxSnapshot;

function snapshot(
  speed: { options: Option[]; current: string } | undefined,
  run: { harness: string; model: string; catalog?: Snapshot["catalog"] } = { harness: "codex", model: "gpt-6-astra" },
): Snapshot {
  const catalog = run.catalog ?? [
    {
      id: run.harness,
      name: run.harness === "codex" ? "Codex" : "Claude Code",
      models: [
        {
          id: run.model,
          name: run.harness === "codex" ? "GPT-6 Astra" : "Claude Opus 5.5",
          fast: true,
          ...(run.harness === "codex" ? { inlineFast: true } : {}),
        },
      ],
    },
  ];
  return {
    type: "snapshot",
    protocolVersion: 1,
    rows: [],
    sessions: [],
    connection: "test",
    isWorking: false,
    queue: [],
    canLoadOlder: false,
    catalog,
    summary: {
      sessionId: "s1",
      harness: run.harness,
      model: run.model,
      turnCount: 1,
      configOptions: [
        {
          id: "reasoning_effort",
          name: "Reasoning",
          category: "thought_level",
          currentValue: "medium",
          options: ["low", "medium", "high"].map((value) => ({ value })),
        },
        ...(speed
          ? [
              {
                id: "fast-mode",
                name: "Fast mode",
                category: "model_config",
                currentValue: speed.current,
                options: speed.options,
              },
            ]
          : []),
      ],
    },
  } as unknown as Snapshot;
}

const sent: string[] = [];
let client: import("@tanstack/react-query").QueryClient;

/// The composer with the real chips. `catalog`: the chips read the joined model catalog, as the app's
/// do, so a model's catalog row decides whether it offers fast mode.
async function render(shot: Snapshot, options: { catalog?: boolean } = {}) {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { Composer } = await import("../src/agent-session/acpmux/Composer");
  const { ComposerPickers } = await import("../src/agent-session/acpmux/ComposerPickers");
  const { usePickerCatalog } = await import("../src/agent-session/acpmux/modelCatalogHost");
  client ??= new QueryClient();
  const Chips = ({ snapshot: chipSnapshot }: { snapshot: Snapshot }) => {
    const picker = usePickerCatalog(chipSnapshot.catalog, { harness: chipSnapshot.summary?.harness }, []);
    return (
      <ComposerPickers
        snapshot={chipSnapshot}
        {...(options.catalog ? { pickerCatalog: picker.catalog } : {})}
        onModel={() => undefined}
        onMode={() => undefined}
        onEffort={(configId, value) => sent.push(`${configId}=${value}`)}
        onHarness={() => undefined}
        showPlan={false}
      />
    );
  };
  root ??= createRoot(host);
  await act(async () => {
    root!.render(
      <QueryClientProvider client={client}>
        <Composer
          snapshot={shot}
          chips={Chips}
          onSend={() => undefined}
          onStop={() => undefined}
          accessory={<button type="button" className="acpmux-mic" aria-label="Dictation" />}
        />
      </QueryClientProvider>,
    );
  });
}

const settle = () => act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));
const chip = () => host.querySelector<HTMLButtonElement>('[data-menu="Model"]')!;
const menu = () => dom.window.document.querySelector<HTMLElement>(".acpmux-quick-menu");
const fastRow = () => menu()?.querySelector<HTMLElement>('.acpmux-quick-fast[role="menuitemcheckbox"]') ?? null;
const rows = () =>
  [...(menu()?.querySelectorAll<HTMLElement>('[role^="menuitem"]') ?? [])].map((item) =>
    item.textContent?.replace("✓", "").trim(),
  );
async function open() {
  if (!menu()) await act(async () => chip().click());
  await settle();
}
async function toggleFast() {
  await act(async () => fastRow()!.click());
  await settle();
}

const twoState: Option[] = [
  { value: "off", name: "Off" },
  { value: "on", name: "On" },
];
const threeTier: Option[] = [{ value: "standard" }, { value: "fast" }, { value: "ultrafast" }];

const claude = { harness: "claude", model: "claude-opus-5-5" };
const codex = { harness: "codex", model: "gpt-6-astra" };
const bolt = () => host.querySelector<HTMLButtonElement>(".acpmux-fast");
async function clickBolt() {
  await act(async () => bolt()!.click());
  await settle();
}

test("Claude: the composer draws no bolt; the model button's menu ends on Fast mode, which toggles the speed option", async () => {
  sent.length = 0;
  await render(snapshot({ options: twoState, current: "off" }, claude));
  expect(bolt()).toBeNull();
  // The box keeps the mic and Send; the quiet row holds the chips and the ring, and no bolt.
  expect(host.querySelector(".acpmux-composer-inner .acpmux-composer-actions .acpmux-mic")).not.toBeNull();
  await open();
  expect(rows().at(-1)).toBe("Fast mode");
  expect(fastRow()!.getAttribute("aria-checked")).toBe("false");
  await toggleFast();
  expect(sent).toEqual(["fast-mode=on"]);

  await render(snapshot({ options: twoState, current: "on" }, claude));
  expect(bolt()).toBeNull();
  // The button never says Fast: the menu row carries it.
  expect(chip().textContent).not.toMatch(/fast/i);
  await open();
  expect(fastRow()!.getAttribute("aria-checked")).toBe("true");
  await toggleFast();
  expect(sent).toEqual(["fast-mode=on", "fast-mode=off"]);
});

test("Codex: the bolt sits beside the model name, and the model button's menu has no Fast mode row", async () => {
  sent.length = 0;
  await render(snapshot({ options: twoState, current: "off" }, codex));
  expect(bolt()).not.toBeNull();
  expect(host.querySelector<HTMLElement>(".acpmux-model")?.contains(bolt())).toBe(true);
  expect(bolt()!.getAttribute("aria-pressed")).toBe("false");
  // A plain outline glyph: no filled bolt, no disc.
  expect(bolt()!.querySelector("svg")!.getAttribute("fill")).toBe("none");
  await clickBolt();
  expect(sent).toEqual(["fast-mode=on"]);
  await open();
  expect(fastRow()).toBeNull();
  expect(rows()).not.toContain("Fast mode");

  await render(snapshot({ options: twoState, current: "on" }, codex));
  expect(bolt()!.getAttribute("aria-pressed")).toBe("true");
  expect(bolt()!.querySelector("svg")!.getAttribute("fill")).toBe("none");
  expect(chip().textContent).not.toMatch(/fast/i);
  await clickBolt();
  expect(sent).toEqual(["fast-mode=on", "fast-mode=off"]);
});

test("Codex: with a tier past Fast, the bolt steps Fast, Ultrafast, then back to off", async () => {
  sent.length = 0;
  await render(snapshot({ options: threeTier, current: "standard" }, codex));
  await clickBolt();
  await render(snapshot({ options: threeTier, current: "fast" }, codex));
  expect(bolt()!.getAttribute("aria-pressed")).toBe("true");
  await clickBolt();
  await render(snapshot({ options: threeTier, current: "ultrafast" }, codex));
  expect(bolt()!.dataset.tier).toBe("ultrafast");
  await clickBolt();
  expect(sent).toEqual(["fast-mode=fast", "fast-mode=ultrafast", "fast-mode=standard"]);
});

test("Codex exposes Fast and Ultrafast from the model-adjacent bolt", async () => {
  sent.length = 0;
  await render(snapshot({ options: threeTier, current: "standard" }, codex));
  expect(bolt()?.textContent).not.toContain("Fast");
  await clickBolt();
  expect(sent).toEqual(["fast-mode=fast"]);
});

test("Claude: with a tier past Fast, any tier on checks the row, and a click goes back to off", async () => {
  sent.length = 0;
  await render(snapshot({ options: threeTier, current: "ultrafast" }, claude));
  await open();
  expect(fastRow()!.getAttribute("aria-checked")).toBe("true");
  await toggleFast();
  expect(sent).toEqual(["fast-mode=standard"]);
  await render(snapshot({ options: threeTier, current: "standard" }, claude));
  await open();
  expect(fastRow()!.getAttribute("aria-checked")).toBe("false");
  await toggleFast();
  expect(sent).toEqual(["fast-mode=standard", "fast-mode=fast"]);
  expect(chip().textContent).not.toMatch(/fast/i);
});

// #20946 brought a separate effort chip back beside the model button; #22800 took it out again.
for (const [name, run] of [
  ["Claude", claude],
  ["Codex", codex],
] as const)
  test(`${name}: no control but the model button names the effort`, async () => {
    await render(snapshot({ options: twoState, current: "off" }, run));
    expect(host.querySelector(".acpmux-effort, .acpmux-effort-menu")).toBeNull();
    const named = [...host.querySelectorAll<HTMLElement>("button, [role=button]")].filter((button) =>
      // No \b: the button's text runs the name into the level ("Opus 5.5Medium").
      /medium|reasoning|effort/i.test(`${button.textContent} ${button.getAttribute("aria-label") ?? ""}`),
    );
    // Identity, not a deep compare: a JSDOM element's graph is circular.
    expect(named.length).toBe(1);
    expect(named[0] === chip()).toBe(true);
    expect(chip().textContent).toContain("Medium");
  });

test("a model with no speed option shows no Fast mode row and no bolt", async () => {
  await render(snapshot(undefined, claude));
  expect(bolt()).toBeNull();
  expect(host.querySelector(".acpmux-composer-actions .acpmux-mic")).not.toBeNull();
  await open();
  expect(menu()).not.toBeNull();
  expect(fastRow()).toBeNull();
});

test("a model whose catalog row has no fast mode shows the row only while fast mode is still on", async () => {
  const { BUNDLED_MODEL_CATALOG } = await import("../src/agent-session/acpmux/modelCatalogData");
  const claude = BUNDLED_MODEL_CATALOG.harnesses.find((harness) => harness.id === "claude")!;
  const slow = claude.models.find((model) => !model.fast && (model.efforts?.length ?? 0) > 0)!;
  const run = {
    harness: "claude",
    model: slow.id,
    catalog: [
      { id: "claude", name: claude.name, models: claude.models.map((model) => ({ id: model.id, name: model.name })) },
    ] as Snapshot["catalog"],
  };
  sent.length = 0;
  await render(snapshot({ options: twoState, current: "off" }, run), { catalog: true });
  await open();
  expect(menu()).not.toBeNull();
  expect(fastRow()).toBeNull();
  await render(snapshot({ options: twoState, current: "on" }, run), { catalog: true });
  await open();
  expect(fastRow()!.getAttribute("aria-checked")).toBe("true");
  await toggleFast();
  expect(sent).toEqual(["fast-mode=off"]);
});
