// The composer's Cloud Environment chip (CloudEnvironmentChip.tsx), behind the launch flag
// CLOUD_ENVIRONMENTS_ENABLED. Leo, 2026-11-07: "you pick the cloud thing, and then you have another
// thing, drop down, or, you know, drop up, that is, because you don't want to hide the composer. So
// the drop up, it goes, like, it's auto by default, but then you can also say create environment."
// And: "maybe we should just name it remote instead of, like, add on another machine."
//   - Where's third row reads Remote;
//   - the chip shows only while Cloud is the pick, and only with the flag on;
//   - its drop-up opens up (never over the composer; the geometry is the gallery's,
//     cloud-environment-chip-geometry.test.ts) and lists Auto, the project's recent environments,
//     New environment…, Edit <current>…, then New Cloud machine…;
//   - Auto is the default and sends no environment; a pick is what the Cloud send names;
//   - New Cloud machine… runs New Cloud Machine with the picked environment; New environment…
//     makes one named after the folder and picks it.
import { afterAll, afterEach, beforeAll, beforeEach, expect, test } from "bun:test";
import { JSDOM } from "jsdom";
import { act } from "react";
import type { Root } from "react-dom/client";
import { translate as t } from "../src/agent-session/acpmux/i18n";
import { teardownDom } from "./support/domTeardown";

const scope = globalThis as Record<string, unknown>;
const keys = [
  "window",
  "document",
  "navigator",
  "IS_REACT_ACT_ENVIRONMENT",
  "HTMLElement",
  "Element",
  "Node",
  "MouseEvent",
  "KeyboardEvent",
  "FocusEvent",
  "PointerEvent",
  "Event",
  "CustomEvent",
  "MutationObserver",
  "ResizeObserver",
  "getComputedStyle",
  "requestAnimationFrame",
  "cancelAnimationFrame",
  "localStorage",
] as const;
const saved = keys.map((key) => [key, key in scope, scope[key]] as const);
let dom: JSDOM;
let root: Root | undefined;
let host: HTMLElement;
let native: [string, Record<string, unknown>][] = [];

const environments = [
  {
    id: "env_default",
    scope: "personal",
    name: "Default",
    is_default: true,
    setup_script: null,
    env_vars: [],
    secrets: [],
    network: { mode: "full", package_managers: true, domains: [] },
    created_at: "1",
    updated_at: "1",
    updated_by: "u",
  },
  ...[
    ["env_web", "atlas-web", "3"],
    ["env_gpu", "GPU training", "2"],
    ["env_old", "old", "1"],
    ["env_docs", "docs", "4"],
  ].map(([id, name, updated]) => ({
    id: id!,
    scope: "personal",
    name: name!,
    is_default: false,
    setup_script: "bun install",
    env_vars: [],
    secrets: [],
    network: { mode: "full", package_managers: true, domains: [] },
    created_at: "1",
    updated_at: updated!,
    updated_by: "u",
  })),
];

beforeAll(() => {
  dom = new JSDOM("<!doctype html><div id=root></div>", { pretendToBeVisual: true, url: "https://cmux.test/" });
  Object.assign(scope, {
    window: dom.window,
    document: dom.window.document,
    navigator: dom.window.navigator,
    IS_REACT_ACT_ENVIRONMENT: true,
    HTMLElement: dom.window.HTMLElement,
    Element: dom.window.Element,
    Node: dom.window.Node,
    MouseEvent: dom.window.MouseEvent,
    KeyboardEvent: dom.window.KeyboardEvent,
    FocusEvent: dom.window.FocusEvent,
    PointerEvent: dom.window.MouseEvent,
    Event: dom.window.Event,
    CustomEvent: dom.window.CustomEvent,
    MutationObserver: dom.window.MutationObserver,
    ResizeObserver: class {
      observe() {}
      unobserve() {}
      disconnect() {}
    },
    getComputedStyle: dom.window.getComputedStyle.bind(dom.window),
    requestAnimationFrame: dom.window.requestAnimationFrame.bind(dom.window),
    cancelAnimationFrame: dom.window.cancelAnimationFrame.bind(dom.window),
    localStorage: dom.window.localStorage,
  });
  host = dom.window.document.getElementById("root")!;
});

beforeEach(async () => {
  native = [];
  dom.window.localStorage.clear();
  (await import("../src/agent-session/acpmux/cloudMachines")).setCloudMachinesForTestAccount(true);
  (await import("../src/agent-session/acpmux/native")).setNativeHost(async (method, params) => {
    native.push([method, params]);
    if (method === "cloud.environment.list") return environments;
    if (method === "cloud.environment.create")
      return { ...environments[1], id: "env_new", name: (params.environment as { name: string }).name };
    return {};
  });
});

afterEach(async () => {
  act(() => root?.unmount());
  root = undefined;
  host.replaceChildren();
  (await import("../src/agent-session/acpmux/native")).setNativeHost(undefined);
  (await import("../src/agent-session/acpmux/composerSettings")).setComposerSettings({ cloudEnvironments: false });
});

afterAll(async () => {
  (await import("../src/agent-session/acpmux/cloudMachines")).setCloudMachinesForTestAccount(undefined);
  await teardownDom(saved, { window: dom.window, scope });
});

const flush = () => act(async () => await new Promise((done) => setTimeout(done, 0)));

/// App.tsx's hold of a new chat's pick (useChatCloudEnvironment): the harness's chat and its send.
let chatSend: ((explicit?: string) => string | undefined) | undefined;

async function mount({ flag, mode, chat: firstChat }: { flag: boolean; mode: "persistent" | "cloud"; chat?: string }) {
  let chat = firstChat;
  const { createRoot } = await import("react-dom/client");
  const { ComposerContext } = await import("../src/agent-session/acpmux/ComposerContext");
  const { useChatCloudEnvironment } = await import("../src/agent-session/acpmux/CloudEnvironmentChip");
  // As App.tsx: the chat's pick rides on its run mode, and its Cloud send takes it.
  function Held(props: Parameters<typeof ComposerContext>[0] & { chat: string }) {
    const { chat: key, ...rest } = props;
    const held = useChatCloudEnvironment(key);
    chatSend = (explicit) => held.forSend(explicit);
    return <ComposerContext {...rest} runMode={{ ...rest.runMode!, environment: held.pick }} />;
  }
  (await import("../src/agent-session/acpmux/composerSettings")).setComposerSettings({ cloudEnvironments: flag });
  const props = {
    environments: true,
    stripLayout: "where-machine",
    summary: { sessionId: "", harness: "claude", host: "This Mac", hostKind: "local", cwd: "/Users/you/src/cmux" },
    localName: "studio-mac",
    projectChoices: [{ cwd: "/Users/you/src/cmux", label: "cmux" }],
    onProject: () => undefined,
    onConnect: () => undefined,
    cloudSignedIn: true,
    runMode: { mode, onMode: () => undefined },
  } as unknown as Parameters<typeof ComposerContext>[0];
  root ??= createRoot(host);
  const render = async (next: Partial<typeof props> & { chat?: string }) => {
    const { chat: nextChat, ...rest } = next;
    if (nextChat !== undefined) chat = nextChat;
    Object.assign(props, rest);
    await act(async () =>
      root!.render(
        <form className="acpmux-composer">
          {chat === undefined ? <ComposerContext {...props} /> : <Held {...props} chat={chat} />}
          <textarea aria-label="Prompt" />
        </form>,
      ),
    );
    await flush();
  };
  await render({});
  return render;
}

const slot = () => host.querySelector<HTMLElement>(".acpmux-cloud-env-slot");
const chipButton = () => slot()?.querySelector<HTMLButtonElement>("button");
const menu = () => dom.window.document.querySelector<HTMLElement>(".acpmux-cloud-env-menu");
const rowLabels = () =>
  [...(menu()?.querySelectorAll<HTMLElement>(".acpmux-menu-item") ?? [])].map(
    (row) => row.querySelector(".acpmux-menu-label")?.textContent ?? "",
  );
const row = (label: string) =>
  [...(menu()?.querySelectorAll<HTMLElement>(".acpmux-menu-item") ?? [])].find(
    (item) => item.querySelector(".acpmux-menu-label")?.textContent === label,
  );
async function openChip() {
  const { openPicker } = await import("../src/agent-session/acpmux/pickerOpeners");
  await act(async () => void openPicker("Environment"));
  await flush();
}

test("Where's third row reads Remote, not Another machine", async () => {
  expect(t("composer.anotherMachine")).toBe("Remote");
  await mount({ flag: false, mode: "persistent" });
  const { openPicker } = await import("../src/agent-session/acpmux/pickerOpeners");
  await act(async () => void openPicker("Computer"));
  const labels = [...dom.window.document.querySelectorAll(".acpmux-env-popover .acpmux-menu-label")].map(
    (label) => label.textContent,
  );
  expect(labels).toContain("Remote");
  expect(labels).not.toContain("Another machine");
});

test("the flag off: no Environment chip, with Cloud picked or not, and nothing is read", async () => {
  const render = await mount({ flag: false, mode: "cloud" });
  expect(slot()).toBeNull();
  await render({ runMode: { mode: "persistent", onMode: () => undefined } } as never);
  expect(slot()).toBeNull();
  expect(native.filter(([method]) => method.startsWith("cloud.environment"))).toEqual([]);
});

test("the flag on: the chip shows only while Cloud is the pick, as the same element", async () => {
  const render = await mount({ flag: true, mode: "persistent" });
  const closed = slot();
  expect(closed?.dataset.shown).toBe("false");
  expect(closed?.hasAttribute("inert")).toBe(true);
  expect(closed?.getAttribute("aria-hidden")).toBe("true");
  await render({ runMode: { mode: "cloud", onMode: () => undefined } } as never);
  // The same element opens (a column transition, cloudEnvironmentChip.css), never a remount that pops in.
  expect(slot()).toBe(closed);
  expect(slot()?.dataset.shown).toBe("true");
  expect(slot()?.hasAttribute("inert")).toBe(false);
  expect(chipButton()?.getAttribute("aria-label")).toBe(`${t("composer.envCloudLabel")}: ${t("composer.envAuto")}`);
  expect(chipButton()?.textContent).toContain(`${t("composer.environment")}: ${t("composer.envAuto")}`);
  // It is the strip's last chip, after Where: nothing before it moves when it opens.
  const leading = host.querySelector(".acpmux-location-leading")!;
  expect(leading.lastElementChild).toBe(slot());
  await render({ runMode: { mode: "persistent", onMode: () => undefined } } as never);
  expect(slot()).toBe(closed);
  expect(slot()?.dataset.shown).toBe("false");
});

test("the drop-up opens up and lists Auto, the recent environments, New, Edit, then New Cloud machine", async () => {
  await mount({ flag: true, mode: "cloud" });
  await openChip();
  expect(menu()).toBeTruthy();
  expect(menu()!.closest("[data-side]")?.getAttribute("data-side") ?? menu()!.getAttribute("data-side")).toBe("top");
  // No picks remembered for this folder: the account's most recently changed ones, three, never the Default.
  expect(rowLabels()).toEqual([
    t("composer.envAuto"),
    "docs",
    "atlas-web",
    "GPU training",
    t("composer.envNew"),
    t("composer.envEdit", { name: "Default" }),
    t("composer.envNewMachine"),
  ]);
  // Auto is checked: it is the default.
  expect(row(t("composer.envAuto"))?.getAttribute("aria-checked")).toBe("true");
});

test("Auto is the default and sends no environment; a pick is what the send names, and leads the folder's list", async () => {
  await mount({ flag: true, mode: "cloud", chat: "new-1" });
  expect(chipButton()?.getAttribute("aria-label")).toBe(`${t("composer.envCloudLabel")}: ${t("composer.envAuto")}`);
  await openChip();
  await act(async () => row("GPU training")!.click());
  await flush();
  expect(chipButton()?.getAttribute("aria-label")).toBe(`${t("composer.envCloudLabel")}: GPU training`);
  await openChip();
  expect(rowLabels().slice(0, 2)).toEqual([t("composer.envAuto"), "GPU training"]);
  expect(rowLabels()).toContain(t("composer.envEdit", { name: "GPU training" }));
});

test("cloud.startChat's payload: Auto and the flag off send today's; a pick goes with one send only", async () => {
  const { startCloudChat } = await import("../src/agent-session/acpmux/cloudRun");
  const { setComposerSettings } = await import("../src/agent-session/acpmux/composerSettings");
  const start = { task: "Fix the build", cwd: "/Users/you/src/cmux", harness: "claude" };
  // What App.tsx sendToCloud hands startCloudChat, and what reaches the host.
  const send = async () => {
    const sent: [string, Record<string, unknown>][] = [];
    let environment: string | undefined;
    act(() => void (environment = chatSend!(undefined)));
    await startCloudChat(
      async (method, params) => void sent.push([method, params]),
      { ...start, ...(environment ? { environment } : {}) },
      "send-1",
    );
    await flush();
    return sent;
  };
  const todayParams: Record<string, unknown> = {
    task: "Fix the build",
    cwd: "/Users/you/src/cmux",
    harness: "claude",
    key: "send-1",
  };
  const today: [string, Record<string, unknown>][] = [["cloud.startChat", todayParams]];
  const withGpu: [string, Record<string, unknown>][] = [
    ["cloud.startChat", { ...todayParams, environment: "env_gpu" }],
  ];
  const pickGpu = async () => {
    await openChip();
    await act(async () => row("GPU training")!.click());
    await flush();
    expect(chipButton()?.getAttribute("aria-label")).toBe(`${t("composer.envCloudLabel")}: GPU training`);
  };
  // The flag off: no chip, and the payload is today's.
  const render = await mount({ flag: false, mode: "cloud", chat: "new-1" });
  expect(slot()).toBeNull();
  expect(await send()).toEqual(today);
  // The flag on, on Auto: still today's, with no `environment`.
  act(() => setComposerSettings({ cloudEnvironments: true }));
  await render({});
  expect(await send()).toEqual(today);
  // A pick goes with the send, and the chat's next send is back on Auto.
  await pickGpu();
  expect(await send()).toEqual(withGpu);
  expect(chipButton()?.getAttribute("aria-label")).toBe(`${t("composer.envCloudLabel")}: ${t("composer.envAuto")}`);
  expect(await send()).toEqual(today);
  // A pick, then a new chat: that chat starts on Auto and sends none.
  await pickGpu();
  await render({ chat: "new-2" });
  expect(chipButton()?.getAttribute("aria-label")).toBe(`${t("composer.envCloudLabel")}: ${t("composer.envAuto")}`);
  expect(await send()).toEqual(today);
  // A pick left when the flag goes off sends nothing either.
  await pickGpu();
  act(() => setComposerSettings({ cloudEnvironments: false }));
  expect(await send()).toEqual(today);
  // A start that names its own environment keeps it.
  act(() => setComposerSettings({ cloudEnvironments: true }));
  let own: string | undefined;
  act(() => void (own = chatSend!("env_web")));
  expect(own).toBe("env_web");
});

test("the GUI hooks: the chip and every drop-up row carry a stable test id", async () => {
  await mount({ flag: true, mode: "cloud" });
  expect(host.querySelector('[data-testid="cloud-environment-chip"] button[data-menu="Environment"]')).toBe(
    chipButton()!,
  );
  await openChip();
  const ids = [...menu()!.querySelectorAll<HTMLElement>("[data-testid]")].map(
    (node) =>
      `${node.dataset.testid}${node.dataset.environmentName && node.dataset.testid === "cloud-environment-option" ? `:${node.dataset.environmentName}` : ""}`,
  );
  expect(ids).toEqual([
    "cloud-environment-auto",
    "cloud-environment-option:docs",
    "cloud-environment-option:atlas-web",
    "cloud-environment-option:GPU training",
    "cloud-environment-new",
    "cloud-environment-edit",
    "cloud-environment-new-machine",
  ]);
});

test("New Cloud machine… runs New Cloud Machine with the picked environment, and with none on Auto", async () => {
  await mount({ flag: true, mode: "cloud" });
  await openChip();
  await act(async () => row(t("composer.envNewMachine"))!.click());
  expect(native.filter(([method]) => method === "action.run")).toEqual([["action.run", { id: "newCloudMachine" }]]);
  native = [];
  await openChip();
  await act(async () => row("atlas-web")!.click());
  await flush();
  await openChip();
  await act(async () => row(t("composer.envNewMachine"))!.click());
  expect(native.filter(([method]) => method === "action.run")).toEqual([
    ["action.run", { id: "newCloudMachine", environment: "env_web" }],
  ]);
});

test("New environment… makes one named after the folder, then picks it; Edit opens the current one", async () => {
  const editor = await import("../src/agent-session/acpmux/cloudEnvironment");
  await mount({ flag: true, mode: "cloud" });
  await openChip();
  await act(async () => row(t("composer.envNew"))!.click());
  const request = editor.cloudEnvironmentRequest();
  expect(request?.create).toEqual({ name: "cmux" });
  expect(request?.section).toBe("script");
  // The editor's store makes it (cloud.environment.create) and reports it; the chip picks it.
  await act(async () => request!.onCreated?.({ ...environments[1]!, id: "env_new", name: "cmux" } as never));
  expect(chipButton()?.getAttribute("aria-label")).toBe(`${t("composer.envCloudLabel")}: cmux`);
  editor.closeCloudEnvironmentRequest(request!.request);
  await openChip();
  await act(async () => row(t("composer.envEdit", { name: "cmux" }))!.click());
  expect(editor.cloudEnvironmentRequest()?.environmentId).toBe("env_new");
});

test("the rows' model: order, the picked one never hidden, Edit names Auto's environment", async () => {
  const choice = await import("../src/agent-session/acpmux/cloudEnvironmentChoice");
  const control = {
    recent: [
      { id: "a", name: "A" },
      { id: "b", name: "B" },
    ],
    current: "z",
    currentName: "Z",
    onPick: () => undefined,
    onNew: () => undefined,
    onEdit: () => undefined,
    onNewMachine: () => undefined,
  };
  expect(choice.cloudEnvironmentRows(control, "Auto").map((row) => row.kind)).toEqual([
    "auto",
    "environment",
    "environment",
    "environment",
    "new",
    "edit",
    "separator",
    "newMachine",
  ]);
  expect(choice.cloudEnvironmentRows(control, "Auto")[3]).toEqual({
    kind: "environment",
    environment: { id: "z", name: "Z" },
  });
  const auto = { ...control, current: choice.AUTO_ENVIRONMENT, auto: { id: "env_default", name: "Default" } };
  expect(choice.cloudEnvironmentRows(auto, "Auto").find((row) => row.kind === "edit")).toEqual({
    kind: "edit",
    name: "Default",
  });
  expect(choice.cloudEnvironmentValue(auto, "Auto")).toBe("Auto");
});

test("the recent list: remembered per folder, most recent first, only environments the account lists", async () => {
  const choice = await import("../src/agent-session/acpmux/cloudEnvironmentChoice");
  const store = new Map<string, string>();
  const kept = {
    getItem: (key: string) => store.get(key) ?? null,
    setItem: (key: string, value: string) => void store.set(key, value),
  };
  choice.rememberEnvironment("/src/a", "env_old", kept);
  choice.rememberEnvironment("/src/a", "env_gone", kept);
  choice.rememberEnvironment("/src/a", "env_web", kept);
  choice.rememberEnvironment("/src/a", choice.AUTO_ENVIRONMENT, kept);
  expect(choice.recentEnvironments("/src/a", environments as never, kept).map((e) => e.id)).toEqual([
    "env_web",
    "env_old",
  ]);
  expect(choice.recentEnvironments("/src/b", environments as never, kept).map((e) => e.id)).toEqual([
    "env_docs",
    "env_web",
    "env_gpu",
  ]);
  expect(choice.autoEnvironment(environments as never)).toEqual({ id: "env_default", name: "Default" });
});
