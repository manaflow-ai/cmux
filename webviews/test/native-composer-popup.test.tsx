import { afterEach, afterAll, expect, test } from "bun:test";
import { act, type ReactNode } from "react";
import { createRoot, type Root } from "react-dom/client";
import { JSDOM } from "jsdom";
import { QueryClient, QueryClientProvider } from "@tanstack/react-query";
import { UiProvider } from "../src/ui/UiProvider";
import { popupAction } from "../src/ui/popupDescriptors";
import type { PopupHost } from "../src/ui/popupHost";
import type { NativePopupEvent, NativePopupModel } from "../src/ui/nativePopup";
import { ComposerPickers, Picker } from "../src/agent-session/acpmux/ComposerPickers";
import type { AcpmuxSnapshot } from "../src/agent-session/acpmux/model";
import { FastToggle } from "../src/agent-session/acpmux/FastToggle";
import { EffortPicker } from "../src/agent-session/acpmux/EffortPicker";
import { AgentOptionsMenu } from "../src/agent-session/acpmux/AgentOptionsMenu";

let dom: JSDOM | undefined;
let root: Root | undefined;
const scope = globalThis as Record<string, unknown>;
const saved = new Map<string, unknown>();

function installDom(): HTMLElement {
  dom = new JSDOM("<!doctype html><html><body><main id=root></main></body></html>", { pretendToBeVisual: true, url: "https://cmux.test" });
  const globals: Record<string, unknown> = {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    HTMLElement: dom.window.HTMLElement,
    HTMLInputElement: dom.window.HTMLInputElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    localStorage: dom.window.localStorage,
    MutationObserver: dom.window.MutationObserver,
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    IS_REACT_ACT_ENVIRONMENT: true,
  };
  for (const [key, value] of Object.entries(globals)) {
    saved.set(key, scope[key]);
    scope[key] = value;
  }
  return dom.window.document.getElementById("root")!;
}

afterEach(() => {
  if (root) act(() => root!.unmount());
  root = undefined;
  dom?.window.close();
  dom = undefined;
  for (const [key, value] of saved) {
    if (value === undefined) delete scope[key];
    else scope[key] = value;
  }
  saved.clear();
});

function nativeHost(accepted = true) {
  const shown: NativePopupModel[] = [];
  const listeners = new Set<(event: NativePopupEvent) => void>();
  const host: PopupHost = {
    show: async () => ({ shown: false }),
    update() {},
    hide() {},
    owner: () => null,
    listen: () => () => {},
    native: {
      show: async (model) => {
        shown.push(model);
        return { shown: accepted };
      },
      update() {},
      hide() {},
      listen(listener) {
        listeners.add(listener);
        return () => listeners.delete(listener);
      },
    },
  };
  return { host, shown, listeners };
}

const wireModels: NativePopupModel[] = [];
afterAll(async () => {
  if (process.env.NATIVE_COMPOSER_WIRE_FIXTURES)
    await Bun.write(process.env.NATIVE_COMPOSER_WIRE_FIXTURES, JSON.stringify(wireModels));
});

async function mount(menu: ReactNode, selector = "button", accepted = true) {
  const container = installDom();
  const native = nativeHost(accepted);
  await act(async () => {
    root = createRoot(container);
    root.render(
      <UiProvider container={container} popupHost={native.host}>
        {menu}
      </UiProvider>,
    );
  });
  const button = container.querySelector<HTMLButtonElement>(selector)!;
  await act(async () => button.click());
  const model = native.shown.at(-1)!;
  expect(model).toBeDefined();
  wireModels.push(model);
  expect(container.querySelector('[role="menu"], [role="listbox"], [role="option"]')).toBeNull();
  const ids = model.rows.map((row) => row.id);
  expect(new Set(ids).size).toBe(ids.length);
  expect(model.rows.every((row) => row.id.length > 0 && row.id.length <= 128)).toBe(true);
  expect(model.rows.every((row) => !row.children && row.kind !== "choice")).toBe(true);
  for (const row of model.rows.filter((row) => row.kind === "action" && !row.disabled))
    expect(popupAction(model, row.id)?.id).toBe(row.id);
  return {
    ...native,
    container,
    button,
    model,
    async pick(label: string) {
      const row = model.rows.find((row) => row.label === label)!;
      expect(row).toBeDefined();
      await act(async () => {
        for (const listener of native.listeners)
          listener({ type: "pick", popupId: model.id, revision: model.revision, id: row.id });
      });
    },
  };
}

test("plus actions preserve keep and close without restoring focus", async () => {
  const picks: string[] = [];
  const menu = await mount(
    <Picker
      label="Add"
      className=""
      button="+"
      align="start"
      returnFocus={false}
      sections={[
        {
          title: "Add",
          choices: [
            { id: "keep", name: "More" },
            { id: "attach", name: "Attach", nativeIcon: "file" },
          ],
          onPick(id) {
            picks.push(id);
            return id === "keep" ? "keep" : undefined;
          },
        },
      ]}
    />,
  );
  expect(menu.model.rows.find((row) => row.label === "Attach")?.icon).toBe("file");
  await menu.pick("More");
  expect(menu.button.getAttribute("aria-expanded")).toBe("true");
  await menu.pick("Attach");
  expect(menu.button.getAttribute("aria-expanded")).toBe("false");
  expect(picks).toEqual(["keep", "attach"]);
  await act(async () => menu.button.click());
  expect(menu.shown).toHaveLength(2);
});

test("native fast pick closes and can reopen without a dismiss event", async () => {
  const picks: string[] = [];
  const menu = await mount(<FastToggle speed={{ off: "", tiers: ["fast"], onPick: (value) => picks.push(value) }} />, ".acpmux-speed-choices");
  const row = menu.model.rows.find((row) => row.checked)!;
  await menu.pick(row.label);
  expect(picks).toEqual([""]);
  expect(menu.button.getAttribute("aria-expanded")).toBe("false");
  await act(async () => menu.button.click());
  expect(menu.shown).toHaveLength(2);
});

test("option IDs distinguish long config IDs and managed disabled rows reject picks", async () => {
  const picks: string[] = [];
  const menu = await mount(
    <AgentOptionsMenu
      managed
      managedReason="Managed"
      onPick={(id, value) => picks.push(id + value)}
      options={[
        {
          id: "x".repeat(500),
          name: "One",
          currentValue: "off",
          options: [
            { value: "full-access", name: "Blocked" },
            { value: "on", name: "Allowed" },
          ],
        },
        { id: "y".repeat(500), name: "Two", currentValue: "off", options: [{ value: "on", name: "Other" }] },
      ]}
    />,
  );
  await menu.pick("Blocked");
  expect(picks).toEqual([]);
  expect(menu.button.getAttribute("aria-expanded")).toBe("true");
  await menu.pick("Other");
  expect(picks).toEqual(["y".repeat(500) + "on"]);
  expect(menu.button.getAttribute("aria-expanded")).toBe("false");
});

test("effort and speed domain values do not collide and default hint survives", async () => {
  const picks: string[] = [];
  const menu = await mount(
    <EffortPicker
      label="Effort"
      defaulted
      current="same"
      efforts={[{ id: "same", name: "High" }]}
      onPick={(id) => picks.push("effort:" + id)}
      speed={{
        title: "Speed",
        current: "off",
        on: "same",
        choices: [{ id: "same", name: "Fast" }],
        onPick: (id) => picks.push("speed:" + id),
      }}
    />,
  );
  expect(menu.model.rows.find((row) => row.label === "High")?.shortcut).toBeTruthy();
  await menu.pick("Fast");
  expect(picks).toEqual(["speed:same"]);
  expect(menu.button.getAttribute("aria-expanded")).toBe("false");
});

test.each(["claude", "codex"])("native %s mode metadata and action preserve harness behavior", async (harness) => {
  const ids = harness === "claude" ? ["auto", "default", "acceptEdits", "plan", "bypassPermissions"] : ["read-only", "auto-review", "agent-full-access"];
  const picks: string[] = [];
  const snapshot = { type: "snapshot", protocolVersion: 1, rows: [], sessions: [], connection: "test", isWorking: false, queue: [], canLoadOlder: false, catalog: [],
    summary: { sessionId: "s", harness, family: harness, model: "default", turnCount: 0, modes: { currentModeId: ids[0], availableModes: ids.map((id) => ({ id, name: id })) } },
  } as unknown as AcpmuxSnapshot;
  const menu = await mount(<QueryClientProvider client={new QueryClient()}><ComposerPickers snapshot={snapshot} showPlan={false}
    onModel={() => {}} onMode={(id) => { picks.push(id); }} onEffort={() => {}} /></QueryClientProvider>, ".acpmux-access-trigger");
  const actions = menu.model.rows.filter((row) => row.kind === "action");
  expect(actions).toHaveLength(ids.length);
  expect(actions.some((row) => row.checked)).toBe(true);
  if (harness === "claude") expect(actions.map((row) => row.shortcut)).toEqual(["1", "2", "3", "4", "5"]);
  else expect(actions.map((row) => row.icon)).toEqual(["permission.ask", "permission.auto", "permission.full-access"]);
  await menu.pick(actions.at(-1)!.label);
  expect(picks).toEqual([ids.at(-1)!]);
  expect(menu.button.getAttribute("aria-expanded")).toBe("false");
});

test("native presentation refusal never mounts the browser popup", async () => {
  const menu = await mount(<FastToggle speed={{ off: "", tiers: ["fast"], onPick() {} }} />, ".acpmux-speed-choices", false);
  expect(menu.button.getAttribute("aria-expanded")).toBe("false");
  expect(menu.container.querySelector('[role="menu"], [role="listbox"], [role="option"]')).toBeNull();
});

test("native reopen ignores a pick from the previous popup revision", async () => {
  const picks: string[] = [];
  const menu = await mount(<FastToggle speed={{ off: "", tiers: ["fast"], onPick: (id) => picks.push(id) }} />, ".acpmux-speed-choices");
  await menu.pick(menu.model.rows[0]!.label);
  await act(async () => menu.button.click());
  await act(async () => {
    for (const listener of menu.listeners)
      listener({ type: "pick", popupId: menu.model.id, revision: menu.model.revision, id: menu.model.rows[1]!.id });
  });
  expect(picks).toEqual([""]);
  expect(menu.button.getAttribute("aria-expanded")).toBe("true");
});
