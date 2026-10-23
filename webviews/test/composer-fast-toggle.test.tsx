// l10n-allow-file: test fixtures.
// Fast mode per harness (Leo 2026-10-21, of a bolt in the box by the mic: "THE BOLT DOESN'T GO
// THERE"). At the composer's boundary: the real composer with the real chips, a stand-in mic, and a
// host that records what the pane sends.
//   - no harness draws a speed control in the box or the row: the bolt button is gone;
//   - the model button's menu ends on a Fast mode checkbox for Claude and Codex alike, checked while
//     any tier past off runs, and a click sends the option's on or off value;
//   - Codex: while a fast tier runs, a small outline bolt sits inside the model button, before the
//     model's name, and the button's tooltip says Fast Mode; off, no bolt;
//   - Claude: no bolt anywhere, on or off;
//   - an option with a tier past Fast (Codex's Ultrafast) adds an Ultrafast checkbox row under Fast
//     mode, checked while that tier runs: on picks it, off steps back to Fast; a two-state option
//     has no such row; a tier past Fast that is not Ultrafast keeps the agent's name for it;
//   - the full picker's Fast mode row reads the same on/off: on (and named) while Ultrafast runs, and
//     a click turns the running tier off;
//   - neither draws an effort control of its own (#20946 brought one back): only the model button
//     names the effort;
//   - the button never says Fast in words;
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
  return {
    type: "snapshot",
    protocolVersion: 1,
    rows: [],
    sessions: [],
    connection: "test",
    isWorking: false,
    queue: [],
    canLoadOlder: false,
    catalog: run.catalog ?? [],
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
async function render(shot: Snapshot, options: { catalog?: boolean; update?: boolean } = {}) {
  const { createRoot } = await import("react-dom/client");
  const { UpdateOfferContext } = await import("../src/agent-session/acpmux/HarnessHealthNotice");
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
        <UpdateOfferContext.Provider
          value={
            options.update
              ? {
                  harness: shot.summary?.harness ?? "claude",
                  agent: "Claude Code",
                  version: "2.1.0",
                  latest: "2.2.0",
                  update: () => undefined,
                  skip: () => undefined,
                }
              : undefined
          }
        >
          <Composer
            snapshot={shot}
            chips={Chips}
            onSend={() => undefined}
            onStop={() => undefined}
            accessory={<button type="button" className="acpmux-mic" aria-label="Dictation" />}
          />
        </UpdateOfferContext.Provider>
      </QueryClientProvider>,
    );
  });
}

const settle = () => act(async () => await new Promise((resolve) => setTimeout(resolve, 0)));
const chip = () => host.querySelector<HTMLButtonElement>('[data-menu="Model"]')!;
const menu = () => dom.window.document.querySelector<HTMLElement>(".acpmux-quick-menu");
const fastRow = () => menu()?.querySelector<HTMLElement>('.acpmux-quick-fast[role="menuitemcheckbox"]') ?? null;
const ultraRow = () => menu()?.querySelector<HTMLElement>('.acpmux-quick-ultrafast[role="menuitemcheckbox"]') ?? null;
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
/// Any speed control in the box or the row (the bolt button #23742 drew left of the mic).
const speedButton = () => host.querySelector<HTMLElement>(".acpmux-fast");
/// The glyph inside the model button that says Codex's fast tier runs.
const boltGlyph = () => chip().querySelector<SVGElement>(".acpmux-model-bolt");
const anyBolt = () => host.querySelector(".acpmux-fast, .acpmux-model-bolt");

test("Claude: no bolt anywhere; the model button's menu ends on Fast mode, which toggles the speed option", async () => {
  sent.length = 0;
  await render(snapshot({ options: twoState, current: "off" }, claude));
  expect(anyBolt()).toBeNull();
  // The box keeps the mic and Send; the quiet row holds the chips and the ring, and no bolt.
  expect(host.querySelector(".acpmux-composer-inner .acpmux-composer-actions .acpmux-mic")).not.toBeNull();
  await open();
  expect(rows().at(-1)).toBe("Fast mode");
  expect(fastRow()!.getAttribute("aria-checked")).toBe("false");
  await toggleFast();
  expect(sent).toEqual(["fast-mode=on"]);

  await render(snapshot({ options: twoState, current: "on" }, claude));
  expect(anyBolt()).toBeNull();
  // The button never says Fast: the menu row carries it.
  expect(chip().textContent).not.toMatch(/fast/i);
  await open();
  expect(fastRow()!.getAttribute("aria-checked")).toBe("true");
  await toggleFast();
  expect(sent).toEqual(["fast-mode=on", "fast-mode=off"]);
});

test("Codex: no speed button in the box; Fast mode is the menu's last row, and a running fast tier is a bolt in the model button", async () => {
  sent.length = 0;
  await render(snapshot({ options: twoState, current: "off" }, codex));
  expect(speedButton()).toBeNull();
  expect(boltGlyph()).toBeNull();
  await open();
  expect(rows().at(-1)).toBe("Fast mode");
  expect(ultraRow()).toBeNull();
  expect(fastRow()!.getAttribute("aria-checked")).toBe("false");
  await toggleFast();
  expect(sent).toEqual(["fast-mode=on"]);

  await render(snapshot({ options: twoState, current: "on" }, codex));
  expect(speedButton()).toBeNull();
  const bolt = boltGlyph()!;
  expect(bolt).not.toBeNull();
  // Before the model's name, inside the one button; an outline glyph, no fill and no disc.
  const name = chip().querySelector(".acpmux-model-name")!;
  expect(bolt.compareDocumentPosition(name) & dom.window.Node.DOCUMENT_POSITION_FOLLOWING).toBeTruthy();
  expect(bolt.getAttribute("fill")).toBe("none");
  expect(bolt.getAttribute("aria-hidden")).toBe("true");
  // The glyph is drawn, not written: the button's text never says Fast; its tooltip does.
  expect(chip().textContent).not.toMatch(/fast/i);
  expect(chip().title).toContain("Fast Mode");
  await open();
  expect(fastRow()!.getAttribute("aria-checked")).toBe("true");
  await toggleFast();
  expect(sent).toEqual(["fast-mode=on", "fast-mode=off"]);
});

test("Codex: with a tier past Fast, any tier on shows the bolt and checks the row; a click goes back to off", async () => {
  sent.length = 0;
  await render(snapshot({ options: threeTier, current: "ultrafast" }, codex));
  expect(speedButton()).toBeNull();
  expect(boltGlyph()).not.toBeNull();
  await open();
  expect(fastRow()!.getAttribute("aria-checked")).toBe("true");
  await toggleFast();
  expect(sent).toEqual(["fast-mode=standard"]);
  await render(snapshot({ options: threeTier, current: "standard" }, codex));
  expect(boltGlyph()).toBeNull();
  await open();
  expect(fastRow()!.getAttribute("aria-checked")).toBe("false");
  await toggleFast();
  expect(sent).toEqual(["fast-mode=standard", "fast-mode=fast"]);
});

test("Codex: a tier past Fast is an Ultrafast row under Fast mode; on picks it, off steps back to Fast", async () => {
  sent.length = 0;
  await render(snapshot({ options: threeTier, current: "fast" }, codex));
  await open();
  expect(rows().slice(-2)).toEqual(["Fast mode", "Ultrafast"]);
  expect(fastRow()!.getAttribute("aria-checked")).toBe("true");
  expect(ultraRow()!.getAttribute("aria-checked")).toBe("false");
  await act(async () => ultraRow()!.click());
  await settle();
  expect(sent).toEqual(["fast-mode=ultrafast"]);

  await render(snapshot({ options: threeTier, current: "ultrafast" }, codex));
  await open();
  expect(ultraRow()!.getAttribute("aria-checked")).toBe("true");
  await act(async () => ultraRow()!.click());
  await settle();
  expect(sent).toEqual(["fast-mode=ultrafast", "fast-mode=fast"]);
  // The button still never says it in words.
  expect(chip().textContent).not.toMatch(/fast/i);
});

// Codex review of #24151: the second row is Codex's Ultrafast only where the tier says so; any other
// harness's tier past Fast keeps the name the agent gives it (else its value), never "Ultrafast".
test("a tier past Fast that is not Ultrafast is a row under Fast mode with the agent's own name for it", async () => {
  sent.length = 0;
  const turbo: Option[] = [{ value: "standard" }, { value: "fast" }, { value: "turbo", name: "Turbo" }];
  await render(snapshot({ options: turbo, current: "fast" }, claude));
  await open();
  expect(rows().slice(-2)).toEqual(["Fast mode", "Turbo"]);
  await act(async () => ultraRow()!.click());
  await settle();
  expect(sent).toEqual(["fast-mode=turbo"]);
  const unnamed: Option[] = [{ value: "standard" }, { value: "fast" }, { value: "priority" }];
  await render(snapshot({ options: unnamed, current: "fast" }, codex));
  await open();
  expect(rows().slice(-2)).toEqual(["Fast mode", "priority"]);
  // Codex's own tier, named or not, reads Ultrafast in the app's words.
  const named: Option[] = [{ value: "standard" }, { value: "fast" }, { value: "ultrafast", name: "ultra fast" }];
  await render(snapshot({ options: named, current: "fast" }, codex));
  await open();
  expect(rows().slice(-2)).toEqual(["Fast mode", "Ultrafast"]);
});

// Codex review of #24151 at 9da89d36: the full picker's Fast mode row read only the first tier as on,
// so with Codex's Ultrafast running it said off and a click picked Fast. It reads the same on/off as
// the menu's row (fastModeToggle): Ultrafast is on, named, and a click turns it off.
/// The full picker, as More models' shortcut (Cmd-Ctrl-M) opens it.
async function openFullPicker() {
  await act(async () =>
    dom.window.dispatchEvent(
      new dom.window.KeyboardEvent("keydown", { key: "m", metaKey: true, ctrlKey: true, bubbles: true }),
    ),
  );
  await settle();
  return dom.window.document.querySelector<HTMLElement>(".acpmux-mp .acpmux-mp-fast")!;
}
test("Codex: the full picker's Fast mode row is on while Ultrafast runs, names it, and a click turns it off", async () => {
  sent.length = 0;
  await render(snapshot({ options: threeTier, current: "ultrafast" }, codex));
  let row = await openFullPicker();
  expect(row.getAttribute("aria-pressed")).toBe("true");
  expect(row.textContent).toContain("Ultrafast");
  await act(async () => row.click());
  await settle();
  expect(sent).toEqual(["fast-mode=standard"]);

  await render(snapshot({ options: threeTier, current: "fast" }, codex));
  row = await openFullPicker();
  expect(row.getAttribute("aria-pressed")).toBe("true");
  await act(async () => row.click());
  await settle();
  expect(sent).toEqual(["fast-mode=standard", "fast-mode=standard"]);

  await render(snapshot({ options: threeTier, current: "standard" }, codex));
  row = await openFullPicker();
  expect(row.getAttribute("aria-pressed")).toBe("false");
  await act(async () => row.click());
  await settle();
  expect(sent).toEqual(["fast-mode=standard", "fast-mode=standard", "fast-mode=fast"]);
});

test("Claude: with a tier past Fast, any tier on checks the row, and a click goes back to off", async () => {
  sent.length = 0;
  await render(snapshot({ options: threeTier, current: "ultrafast" }, claude));
  expect(anyBolt()).toBeNull();
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
  expect(anyBolt()).toBeNull();
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

// Leo 2026-10-21: "BRO WTF NO WE FUCKING HATE THE DOT". Lawrence's build read "Opus 5.5 • Medium": the
// chip drew an agent-update dot between the model's name and its effort. The button reads the model,
// then its effort, and nothing between them, in every form the row can give it.
for (const [name, run] of [
  ["Claude", claude],
  ["Codex", codex],
] as const)
  test(`${name}: the model button has no dot between the model and its effort, even with an agent update on offer`, async () => {
    for (const current of ["off", "on"])
      for (const update of [false, true]) {
        await render(snapshot({ options: twoState, current }, run), { update });
        const button = chip();
        // Every label the button can show: its text and each fit form's drawn label (data-label).
        const labels = [
          button.textContent ?? "",
          ...[...button.querySelectorAll<HTMLElement>("[data-label]")].map((part) => part.dataset.label ?? ""),
        ];
        for (const label of labels)
          expect(label, `${current}, update ${update}`).not.toMatch(/[•·\u2022\u00b7\u2219\u22c5]/);
        // No dot drawn as an element either: between the name and the effort sits nothing but the effort.
        expect(button.querySelector(".acpmux-model-update-dot, .rounded-full")).toBeNull();
        const name = button.querySelector(".acpmux-model-name")!;
        const effort = button.querySelector(".acpmux-model-detail")!;
        let between = name.nextElementSibling;
        const drawn: string[] = [];
        while (between && between !== effort) {
          if (!between.classList.contains("acpmux-model-short")) drawn.push(between.className);
          between = between.nextElementSibling;
        }
        expect(drawn, `${current}, update ${update}`).toEqual([]);
        if (update) expect(button.title).toContain("2.2.0");
      }
  });
