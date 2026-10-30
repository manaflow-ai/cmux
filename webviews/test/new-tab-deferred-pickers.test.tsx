// A New Tab's picker uses the same ComposerPickers path as an active chat. A typed
// model/effort/fast combo picked before the deferred chat has a session goes into the harness
// switch's config, so a prompt sent right after it runs its first turn on the whole combo: the
// switch applies the picks, mapped onto the options the opened session names, before the prompt.
import { afterAll, afterEach, beforeAll, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act, useSyncExternalStore } from "react";
import type { Root } from "react-dom/client";
import { effortLevel } from "./support/effortDropdown";

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
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    ResizeObserver:
      w.ResizeObserver ??
      class {
        observe() {}
        unobserve() {}
        disconnect() {}
      },
  });
  host = dom.window.document.getElementById("root")!;
});

afterEach(() => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  dom.window.localStorage.clear();
});

afterAll(() => {
  dom.window.close();
  for (const [key, had, value] of saved) {
    if (had) scope[key] = value;
    else delete scope[key];
  }
});

type Snapshot = import("../src/agent-session/acpmux/model").AcpmuxSnapshot;
type Option = NonNullable<NonNullable<Snapshot["summary"]>["configOptions"]>[number];

const effortOption = (id = "effort", values = ["low", "medium", "high"]): Option => ({
  id,
  name: "Effort",
  category: "thought_level",
  currentValue: "medium",
  options: values.map((value) => ({ value, name: value })),
});
const fastOption = (id = "fast-mode", values: string[] = ["off", "on"]): Option => ({
  id,
  name: "Fast mode",
  currentValue: values[0],
  options: values.map((value) => ({ value, name: value })),
});

/// A New Tab pane as App wires it: its chips draw the harness switch's view of the page's empty
/// summary, and a pick starts the deferred chat (`chat.new {deferred}`) and goes to the switch
/// (`chat.model`, `chat.effort`). The port records what reaches acpmux once the session opens with
/// `opened` as its options; the page's summary then reports that session (its id, harness, model and
/// the values set on it), so the composer's after-open fallbacks run and any late or second send
/// shows on the wire. `tiers`: the service tiers the model catalog lists for `harness`'s models
/// (pendingSpeed.ts draws them as the Fast option before a session). `live`: the pane already shows
/// a session on `harness` with a turn streaming, and acpmux answers a set model or option only when
/// the test lets it (`answer`), so an answer can still be in flight when the next thing happens.
async function mountNewTab({
  opened,
  harness = "claude",
  model = "claude-sonnet-5-5",
  tiers,
  live,
  rail = false,
  remembered = false,
  startedChat = false,
}: {
  opened: Option[];
  harness?: string;
  model?: string;
  tiers?: string[];
  live?: boolean;
  rail?: boolean;
  remembered?: boolean;
  startedChat?: boolean;
}) {
  const { createRoot } = await import("react-dom/client");
  const { QueryClient, QueryClientProvider } = await import("@tanstack/react-query");
  const { ComposerPickers } = await import("../src/agent-session/acpmux/ComposerPickers");
  const { usePickerCatalog } = await import("../src/agent-session/acpmux/modelCatalogHost");
  const { BUNDLED_MODEL_CATALOG } = await import("../src/agent-session/acpmux/modelCatalogData");
  const { HarnessSwitch, applySwitch } = await import("../src/agent-session/acpmux/harnessSwitch");
  const { HarnessProfiles } = await import("../src/agent-session/acpmux/harnessProfiles");
  const catalog = BUNDLED_MODEL_CATALOG.harnesses.map((entry) => ({
    id: entry.id,
    name: entry.name,
    family: entry.families[0],
    models: entry.models.map((choice) => ({
      id: choice.id,
      name: choice.name,
      ...(tiers && entry.id === harness ? { serviceTiers: tiers } : {}),
    })),
  })) as Snapshot["catalog"];
  // A fresh page knows no options; a remembered profile uses the previous session's names.
  const profiles = new HarnessProfiles(() => undefined);
  if (remembered) profiles.observe({ sessionId: "previous", harness, model, turnCount: 1, configOptions: opened });
  const wire: string[] = [];
  let open = live !== undefined;
  let started = harness;
  let running = model;
  // The session's options as it reports them: each set value becomes the option's current one.
  const options = opened.map((option) => ({ ...option }));
  // What acpmux reports changed: the pane draws the summary again.
  let version = 0;
  const listeners = new Set<() => void>();
  const reported = () => {
    version += 1;
    for (const listener of listeners) listener();
  };
  const subscribe = (listener: () => void) => {
    listeners.add(listener);
    return () => void listeners.delete(listener);
  };
  // acpmux's answers a live test has not let land yet, by kind.
  const inFlight: { kind: "model" | "config"; land: () => void }[] = [];
  const later = (kind: "model" | "config") =>
    live ? new Promise<void>((land) => void inFlight.push({ kind, land })) : undefined;
  const store = new HarnessSwitch();
  store.connect({
    turnRunning: () => live !== undefined,
    shown: () =>
      open ? { sessionId: "s-1", harness: started, model: running, empty: !live, configOptions: options } : undefined,
    create: async (agent: string) => {
      wire.push(`new ${agent}`);
      if (!live) started = agent;
      return live ? "s-2" : "s-1";
    },
    leave: () => undefined,
    open: async (sessionId: string) => {
      open = true;
      return sessionId;
    },
    send: async (text: string) => void wire.push(`prompt ${text}`),
    setModel: async (modelId: string) => {
      wire.push(`model ${modelId}`);
      await later("model");
      running = modelId;
      reported();
    },
    setMode: async () => undefined,
    setConfig: async (configId: string, value: string) => {
      wire.push(`${configId}=${value}`);
      await later("config");
      const option = options.find((candidate) => candidate.id === configId);
      if (option) option.currentValue = value;
      reported();
    },
    discard: () => undefined,
    prewarm: () => undefined,
    prewarmSupported: () => false,
  });
  const raw = (): Snapshot =>
    ({
      type: "snapshot",
      protocolVersion: 1,
      rows: [],
      sessions: [],
      connection: "test",
      isWorking: false,
      queue: [],
      canLoadOlder: false,
      catalog,
      summary: open
        ? {
            sessionId: "s-1",
            harness: started,
            model: running,
            turnCount: startedChat ? 1 : 0,
            configOptions: options.map((o) => ({ ...o })),
          }
        : { sessionId: "", harness, model, turnCount: 0 },
    }) as Snapshot;
  // The page's chat.new names the harness its chips draw: the switch's, once a pick made one. Once
  // the chat has its session, App's chips start nothing (`start` in DefaultComposerChips).
  const start = () => {
    if (!open) void store.switchTo(store.view().intent?.harness ?? harness, "/tmp/project", { deferred: true });
  };
  // App's chat.model and chat.effort: held during the switch, else sent to the open session.
  const shownSession = () => (open ? { sessionId: "s-1", model: running } : undefined);

  function Host() {
    const view = useSyncExternalStore(store.subscribe, store.view);
    useSyncExternalStore(subscribe, () => version);
    const snapshot = applySwitch(raw(), view, catalog, profiles);
    const picker = usePickerCatalog(
      snapshot.catalog,
      { harness: snapshot.summary?.harness, configOptions: snapshot.summary?.configOptions },
      [],
    );
    return (
      <ComposerPickers
        snapshot={snapshot}
        pickerCatalog={picker.catalog}
        holdsModePick
        {...(rail ? { fork: { to: () => undefined, ready: true } } : {})}
        onModel={(modelId) => {
          start();
          void store.pickModel(modelId, shownSession());
        }}
        onMode={() => undefined}
        onEffort={(configId, value) => {
          start();
          store.pickConfig(configId, value, shownSession());
        }}
        // App's chat.new for a pick of another harness: a switch carrying the combo (deferred on a
        // New Tab page).
        onHarness={(agent, picked, held) =>
          void store.switchTo(agent, "/tmp/project", {
            deferred: !live,
            ...(picked ? { model: picked } : {}),
            ...(held ? { options: held } : {}),
          })
        }
        showPlan={false}
      />
    );
  }

  const client = new QueryClient();
  root = createRoot(host);
  await act(async () => {
    root!.render(
      <QueryClientProvider client={client}>
        <Host />
      </QueryClientProvider>,
    );
  });
  const pickCombo = async (query: string, label: string) => {
    // Cmd-Ctrl-M opens the same compact picker as the model button; typing filters its rows.
    await act(async () => {
      dom.window.dispatchEvent(new dom.window.KeyboardEvent("keydown", { key: "m", metaKey: true, ctrlKey: true }));
    });
    const menu = dom.window.document.querySelector<HTMLElement>(".acpmux-quick-menu");
    if (!menu) {
      const trigger = host.querySelector<HTMLElement>("[data-menu=Model]");
      expect(trigger).not.toBeNull();
      await act(async () => trigger!.click());
    }
    const openMenu = dom.window.document.querySelector<HTMLElement>(".acpmux-quick-menu");
    expect(openMenu).not.toBeNull();
    const search = openMenu!.querySelector<HTMLInputElement>(".acpmux-quick-search input");
    expect(search).not.toBeNull();
    const setter = Object.getOwnPropertyDescriptor(dom.window.HTMLInputElement.prototype, "value")!.set!;
    await act(async () => {
      setter.call(search, query);
      search!.dispatchEvent(new dom.window.Event("input", { bubbles: true }));
    });
    const row = [
      ...dom.window.document.querySelectorAll<HTMLElement>('.acpmux-quick-menu [role="menuitemradio"]'),
    ].find((candidate) => candidate.textContent?.includes(label));
    expect(row).not.toBeUndefined();
    await act(async () => row!.dispatchEvent(new dom.window.MouseEvent("click", { bubbles: true })));
  };
  const settle = async () => {
    for (let turn = 0; turn < 5; turn++) await new Promise((done) => setTimeout(done, 0));
  };
  // Return right after the pick (App's chat.new, then chat.send): the prompt queues on the switch,
  // which opens the chat, applies the picks and then sends it. With no switch holding it (a live
  // chat), it goes straight to the session, as App's send does.
  const send = async (text: string) =>
    act(async () => {
      start();
      if (!store.send(text)) wire.push(`prompt ${text}`);
      await settle();
    });
  // acpmux answers every request of `kind` still in flight (a live test's), and reports the result.
  const answer = async (kind: "model" | "config") =>
    act(async () => {
      const landing = inFlight.filter((request) => request.kind === kind);
      inFlight.splice(0, inFlight.length, ...inFlight.filter((request) => request.kind !== kind));
      for (const request of landing) request.land();
      await settle();
    });
  const pickInline = async () => {
    await act(async () => host.querySelector<HTMLElement>("[data-menu=Model]")!.click());
    expect(Boolean(dom.window.document.querySelector(".acpmux-quick-rail"))).toBe(!startedChat || rail);
    const high = await effortLevel(dom.window.document, "Sonnet 5.5 · High");
    expect(high).not.toBeNull();
    await act(async () => high!.click());
  };
  return { wire, pickCombo, pickInline, send, answer, held: () => store.view().intent?.config };
}

test("a New Tab combo's effort and Fast reach the chat before the prompt sent right after it", async () => {
  const { wire, pickCombo, send } = await mountNewTab({ opened: [effortOption(), fastOption()] });
  await pickCombo("opus high fast", "Opus 5.5");
  await send("hello");
  expect(wire).toEqual(["new claude", "model claude-opus-5-5", "effort=high", "fast-mode=on", "prompt hello"]);
});

test("a New Tab combo for the model already shown still carries its effort into the first turn", async () => {
  const { wire, pickCombo, send } = await mountNewTab({ opened: [effortOption(), fastOption()] });
  await pickCombo("sonnet high", "Sonnet 5.5");
  await send("hello");
  expect(wire).toEqual(["new claude", "effort=high", "prompt hello"]);
});

test("a held New Tab combo takes the opened session's own option names and values", async () => {
  // A harness that names its effort another way and its Fast mode with true/false.
  const { wire, pickCombo, send } = await mountNewTab({
    opened: [effortOption("reasoning_effort"), fastOption("fast_mode", ["false", "true"])],
  });
  await pickCombo("opus high fast", "Opus 5.5");
  await send("hello");
  expect(wire).toEqual([
    "new claude",
    "model claude-opus-5-5",
    "reasoning_effort=high",
    "fast_mode=true",
    "prompt hello",
  ]);
});

test("a held Fast pick the opened session does not offer is not sent", async () => {
  const { wire, pickCombo, send } = await mountNewTab({ opened: [effortOption()] });
  await pickCombo("opus high fast", "Opus 5.5");
  await send("hello");
  expect(wire).toEqual(["new claude", "model claude-opus-5-5", "effort=high", "prompt hello"]);
});

test("a session that reports no options takes none of the held picks", async () => {
  const { wire, pickCombo, send } = await mountNewTab({ opened: [] });
  await pickCombo("opus high fast", "Opus 5.5");
  await send("hello");
  expect(wire).toEqual(["new claude", "model claude-opus-5-5", "prompt hello"]);
});

test("a held effort the opened session does not offer is not sent, and no other level stands in", async () => {
  const { wire, pickCombo, send } = await mountNewTab({
    opened: [effortOption("effort", ["low", "medium"]), fastOption()],
  });
  await pickCombo("opus high fast", "Opus 5.5");
  await send("hello");
  expect(wire).toEqual(["new claude", "model claude-opus-5-5", "fast-mode=on", "prompt hello"]);
});

// Codex review of #24509: a combo for another harness sent only its model into the switch, so the
// first prompt ran without its effort and Fast (they followed after the first turn).
test("a New Tab combo for another harness carries its effort and Fast into that chat's first turn", async () => {
  const { wire, pickCombo, send } = await mountNewTab({
    opened: [effortOption("reasoning_effort"), fastOption("fast_mode", ["false", "true"])],
  });
  await pickCombo("astra high fast", "Astra");
  await send("hello");
  expect(wire).toEqual(["new codex", "model gpt-6-astra", "reasoning_effort=high", "fast_mode=true", "prompt hello"]);
});

// Codex review of #24509 at 348093f4: a tiered Fast option (standard, fast, ultrafast) lists no
// on-like value, so a combo's generic Fast on was dropped and Fast came only after the first turn.
test("a combo's Fast reaches a tiered Fast option as its fast tier, never ultrafast, before the first prompt", async () => {
  const { wire, pickCombo, send } = await mountNewTab({
    opened: [effortOption("reasoning_effort"), fastOption("fast_mode", ["standard", "fast", "ultrafast"])],
  });
  await pickCombo("astra high fast", "Astra");
  await send("hello");
  expect(wire).toEqual(["new codex", "model gpt-6-astra", "reasoning_effort=high", "fast_mode=fast", "prompt hello"]);
});

test("a generic Fast on or off takes the option's own spelling, and on never becomes a higher tier", async () => {
  const { heldOptionPick } = await import("../src/agent-session/acpmux/heldOptions");
  const tiered = [fastOption("fast_mode", ["standard", "fast", "ultrafast"])];
  expect(heldOptionPick("fast-mode", "on", tiered)).toEqual({ configId: "fast_mode", value: "fast" });
  expect(heldOptionPick("fast-mode", "off", tiered)).toEqual({ configId: "fast_mode", value: "standard" });
  // The model catalog's tiers (pendingSpeed.ts) name the same ones priority and default.
  expect(heldOptionPick("fast-mode", "priority", tiered)).toEqual({ configId: "fast_mode", value: "fast" });
  expect(heldOptionPick("fast-mode", "default", tiered)).toEqual({ configId: "fast_mode", value: "standard" });
  // Only a higher tier past standard: nothing stands in for plain fast.
  expect(heldOptionPick("fast-mode", "on", [fastOption("fast_mode", ["standard", "ultrafast"])])).toBeUndefined();
  expect(heldOptionPick("fast-mode", "on", [fastOption("fast", ["false", "true"])])).toEqual({
    configId: "fast",
    value: "true",
  });
});

// Codex review of #24509 at 08e1ab45: before a session, a Codex New Tab draws Fast from the model
// catalog's tiers (default, priority, ultrafast, pendingSpeed.ts), and a combo held "priority",
// which a session naming its tiers standard, fast and ultrafast did not take: Fast was lost.
test("a combo's Fast held on catalog tiers reaches a session that names them standard, fast and ultrafast", async () => {
  const { wire, pickCombo, send } = await mountNewTab({
    harness: "codex",
    model: "gpt-6.1-sol",
    tiers: ["priority", "ultrafast"],
    opened: [effortOption("reasoning_effort"), fastOption("fast_mode", ["standard", "fast", "ultrafast"])],
  });
  await pickCombo("astra high fast", "Astra");
  await send("hello");
  expect(wire).toEqual(["new codex", "model gpt-6-astra", "reasoning_effort=high", "fast_mode=fast", "prompt hello"]);
});

// Same review: the composer's after-open fallback sent the option's second value (ultrafast) where
// the switch had rightly sent nothing.
test("a session whose Fast tiers are standard and ultrafast gets no Fast at all from a combo", async () => {
  const { wire, pickCombo, send } = await mountNewTab({
    opened: [effortOption("reasoning_effort"), fastOption("fast_mode", ["standard", "ultrafast"])],
  });
  await pickCombo("astra high fast", "Astra");
  await send("hello");
  expect(wire).toEqual(["new codex", "model gpt-6-astra", "reasoning_effort=high", "prompt hello"]);
});

// Same review: a combo back to the harness of the chat still on screen (a turn streaming) had the
// switch and the composer both send its effort and Fast; an answer still in flight when the model
// reported made the composer send them again.
test("a combo back to the chat on screen sends its effort and Fast once, with acpmux's answers delayed", async () => {
  const { wire, pickCombo, send, answer } = await mountNewTab({ opened: [effortOption(), fastOption()], live: true });
  await pickCombo("astra", "Astra");
  await pickCombo("opus high fast", "Opus 5.5");
  // Return at once: the prompt goes before acpmux has answered anything.
  await send("hello");
  // acpmux reports the model while the effort and Fast answers are still in flight, then answers them.
  await answer("model");
  await answer("config");
  const sent = wire.filter((line) => !line.startsWith("new "));
  expect(sent[0]).toBe("model claude-opus-5-5");
  expect([...sent].sort()).toEqual(["effort=high", "fast-mode=on", "model claude-opus-5-5", "prompt hello"]);
});

for (const rail of [false, true]) {
  test(`a live compact row switches Fable Medium to Sonnet High after model confirmation (rail=${rail})`, async () => {
    const { wire, pickInline, answer } = await mountNewTab({
      model: "claude-fable-5-1",
      opened: [effortOption("reasoning_effort")],
      live: true,
      startedChat: true,
      rail,
    });
    await pickInline();
    expect(wire).toEqual(["model claude-sonnet-5-5"]);
    await answer("model");
    expect(wire).toEqual(["model claude-sonnet-5-5", "reasoning_effort=high"]);
    await answer("config");
    expect(host.querySelector(".acpmux-model-detail")?.textContent).toBe("High");
  });
}

for (const remembered of [false, true]) {
  test(`a New Tab compact row holds Sonnet High on the chip and starts its first turn with it (remembered=${remembered})`, async () => {
    const { wire, pickInline, send, held } = await mountNewTab({
      model: "claude-fable-5-1",
      opened: [effortOption("reasoning_effort")],
      remembered,
    });
    await pickInline();
    expect(held()).toEqual({ model: "claude-sonnet-5-5", options: { effort: "high" } });
    const detail = host.querySelector(".acpmux-model-detail")?.textContent;
    await send("hello");
    expect(wire).toEqual(["new claude", "model claude-sonnet-5-5", "reasoning_effort=high", "prompt hello"]);
    expect(detail).toBe("High");
  });
}

test("a New Tab replaces held Sonnet High with Medium after switching to Codex and back", async () => {
  const { wire, pickInline, pickCombo, send, held } = await mountNewTab({
    model: "claude-fable-5-1",
    opened: [effortOption("reasoning_effort")],
  });
  await pickInline();
  expect(host.querySelector(".acpmux-model-name")?.textContent).toBe("Sonnet 5.5");
  expect(host.querySelector(".acpmux-model-detail")?.textContent).toBe("High");

  await pickCombo("astra", "Astra");
  expect(held()?.model).toBe("gpt-6-astra");
  await act(async () => host.querySelector<HTMLElement>("[data-menu=Model]")!.click());
  const claude = dom.window.document.querySelector<HTMLElement>('.acpmux-quick-rail-tab[aria-label^="Claude"]');
  expect(claude).not.toBeNull();
  await act(async () => claude!.click());
  const medium = await effortLevel(dom.window.document, "Sonnet 5.5 · Medium");
  expect(medium).not.toBeNull();
  await act(async () => medium!.click());

  expect(host.querySelector(".acpmux-model-name")?.textContent).toBe("Sonnet 5.5");
  expect(host.querySelector(".acpmux-model-detail")?.textContent).toBe("Medium");
  expect(held()).toEqual({ model: "claude-sonnet-5-5", options: { effort: "medium" } });
  expect(wire).toEqual(["new claude", "new codex", "new claude"]);
  await send("hello");
  expect(wire).toEqual([
    "new claude",
    "new codex",
    "new claude",
    "model claude-sonnet-5-5",
    "reasoning_effort=medium",
    "prompt hello",
  ]);
});
